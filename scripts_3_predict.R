# scripts_4_predict.R
# Parameterized block-wise raster prediction and merging using a saved QRF model
# Usage: Rscript scripts/scripts_4_predict.R [path/to/config.yml]
#
# Expects:
# - best_features .rds files (character vector of feature names or indices)
# - final_qrf_model.rds (saved learner or quantregForest/ranger object)
# - raster stack tiles named by pattern (raster_stack_*.tif) in raster_stack_dir
# Outputs:
# - per-block pred/lower/upper tifs and merged mosaics saved to prediction$cache_dir (from config)

suppressPackageStartupMessages({
  library(yaml)
  library(raster)
  library(readr)
})

args <- commandArgs(trailingOnly = TRUE)
cfg_path <- ifelse(length(args) >= 1, args[[1]], "config.yml")
if (!file.exists(cfg_path)) stop("config.yml not found.")
cfg <- yaml::read_yaml(cfg_path)

seed <- cfg$seed %||% 666
set.seed(seed)

raster_stack_dir <- cfg$raster_stack_dir %||% "Block/Forests_Raster_stack_item"
input_dir <- cfg$input_dir %||% "data"
output_cache <- cfg$prediction$cache_dir %||% file.path(cfg$output_dir %||% "outputs", "cache")
dir.create(output_cache, recursive = TRUE, showWarnings = FALSE)

best_features_suffix <- cfg$best_features_suffix %||% "_best_features.rds"
final_model_suffix <- cfg$final_model_suffix %||% "_final_qrf_model.rds"
checkpoint_suffix <- cfg$prediction$checkpoint_suffix %||% "_checkpoint.rds"
raster_pattern <- cfg$raster_stack_pattern %||% "^raster_stack_.*\\.tif$"
quantiles <- cfg$prediction$quantiles %||% c(0.05, 0.5, 0.95)

# helper: merge list of rasters (fallback mosaic with mean)
merge_rasters <- function(rlist) {
  if (length(rlist) == 0) return(NULL)
  if (length(rlist) == 1) return(rlist[[1]])
  res <- rlist[[1]]
  for (i in 2:length(rlist)) {
    res <- tryCatch({
      mosaic(res, rlist[[i]], fun = mean, tolerance = 0.1, na.rm = TRUE)
    }, error = function(e) {
      warning("Mosaic error: ", e$message)
      res
    })
  }
  return(res)
}

save_block_results <- function(pred_raster, lower_raster, upper_raster, cache_dir, output_prefix, file_suffix) {
  writeRaster(pred_raster, file.path(cache_dir, paste0(output_prefix, "_", file_suffix, "_pred.tif")), format = "GTiff", overwrite = TRUE)
  writeRaster(lower_raster, file.path(cache_dir, paste0(output_prefix, "_", file_suffix, "_lower.tif")), format = "GTiff", overwrite = TRUE)
  writeRaster(upper_raster, file.path(cache_dir, paste0(output_prefix, "_", file_suffix, "_upper.tif")), format = "GTiff", overwrite = TRUE)
  message("Saved block files for ", file_suffix)
}

save_results <- function(pred_rasters, lower_rasters, upper_rasters, cache_dir, output_prefix) {
  pred_mosaic <- merge_rasters(pred_rasters)
  lower_mosaic <- merge_rasters(lower_rasters)
  upper_mosaic <- merge_rasters(upper_rasters)
  if (!is.null(pred_mosaic)) writeRaster(pred_mosaic, file.path(cache_dir, paste0(output_prefix, "_pred.tif")), format = "GTiff", overwrite = TRUE)
  if (!is.null(lower_mosaic)) writeRaster(lower_mosaic, file.path(cache_dir, paste0(output_prefix, "_lower.tif")), format = "GTiff", overwrite = TRUE)
  if (!is.null(upper_mosaic)) writeRaster(upper_mosaic, file.path(cache_dir, paste0(output_prefix, "_upper.tif")), format = "GTiff", overwrite = TRUE)
  message("Saved merged mosaics for ", output_prefix)
}

# loop over combined data files to determine sample prefixes (consistent with earlier steps)
combined_files <- list.files(input_dir, pattern = cfg$combined_pattern %||% "_combined_data.csv$", full.names = TRUE)
if (length(combined_files) == 0) {
  message("No combined data files found in ", input_dir)
}

# find raster tiles
processed_files <- list.files(raster_stack_dir, pattern = raster_pattern, full.names = TRUE)
if (length(processed_files) == 0) {
  stop("No raster stack tiles found in raster_stack_dir: ", raster_stack_dir)
}

for (sample_file in combined_files) {
  base <- tools::file_path_sans_ext(basename(sample_file))
  output_prefix <- sub("_combined_data$", "", base)
  # locate best features and final model for this prefix
  bf_candidates <- c(
    file.path(input_dir, paste0(base, best_features_suffix)),
    file.path(output_cache, paste0(base, best_features_suffix))
  )
  bf_file <- NULL
  for (c in bf_candidates) if (file.exists(c)) { bf_file <- c; break }
  if (is.null(bf_file)) { message("Best features not found for ", base, "; skipping."); next }
  best_features <- readRDS(bf_file)

  model_candidates <- c(
    file.path(output_cache, paste0(base, final_model_suffix)),
    file.path(input_dir, paste0(base, final_model_suffix)),
    file.path(cfg$output_dir %||% "outputs", paste0(base, final_model_suffix))
  )
  model_file <- NULL
  for (m in model_candidates) if (file.exists(m)) { model_file <- m; break }
  if (is.null(model_file)) { message("Final model not found for ", base, "; skipping."); next }
  final_model <- readRDS(model_file)

  # checkpoint init
  checkpoint_file <- file.path(output_cache, paste0(output_prefix, checkpoint_suffix))
  checkpoint <- if (file.exists(checkpoint_file)) readRDS(checkpoint_file) else list(processed_files = character(0))

  pred_rasters <- list(); lower_rasters <- list(); upper_rasters <- list()

  for (processed_file in processed_files) {
    fname <- basename(processed_file)
    if (fname %in% checkpoint$processed_files) {
      message("Skipping already processed tile: ", fname)
      # still load saved rasters to include in mosaics
      pred_path <- file.path(output_cache, paste0(output_prefix, "_", gsub("raster_stack_|\\.tif$", "", fname), "_pred.tif"))
      if (file.exists(pred_path)) pred_rasters <- append(pred_rasters, list(raster(pred_path)))
      next
    }

    message("Processing tile: ", processed_file)
    rst <- tryCatch({ stack(processed_file) }, error = function(e) { message("Read tile error: ", e$message); NULL })
    if (is.null(rst)) next

    # Select layers by name if best_features are names, else by index if numeric
    rst_selected <- tryCatch({
      if (is.numeric(best_features) || all(grepl("^[0-9]+$", as.character(best_features)))) {
        idx <- as.integer(best_features)
        rst[[idx]]
      } else {
        # try matching layer names
        available_names <- names(rst)
        matched <- intersect(as.character(best_features), available_names)
        if (length(matched) == 0) stop("No matching raster layer names for best_features in tile.")
        rst[[matched]]
      }
    }, error = function(e) { message("Selecting layers error: ", e$message); NULL })

    if (is.null(rst_selected)) next

    # predict: support different model object types
    predicted_rasters <- list()
    for (q in quantiles) {
      pr <- tryCatch({
        if (inherits(final_model, "Learner") && final_model$predict_type == "response") {
          # mlr3 learner: use raster::predict with wrapper predicting center estimate only
          # if quantiles required and learner supports them, user is responsible for providing model supporting quantiles
          predict(rst_selected, final_model, what = ifelse(q == 0.5, 0.5, q))
        } else if (inherits(final_model, "rq") || inherits(final_model, "randomForest")) {
          predict(rst_selected, final_model, type = "response")
        } else {
          # fallback: try predict(rst_selected, final_model)
          predict(rst_selected, final_model)
        }
      }, error = function(e) { message("Prediction error for quantile ", q, ": ", e$message); NULL })
      predicted_rasters <- append(predicted_rasters, list(pr))
    }

    # assign predicted rasters (assuming quantiles in order defined)
    if (length(predicted_rasters) >= 3) {
      lower_rasters <- append(lower_rasters, list(predicted_rasters[[1]]))
      pred_rasters <- append(pred_rasters, list(predicted_rasters[[2]]))
      upper_rasters <- append(upper_rasters, list(predicted_rasters[[3]]))
    } else if (length(predicted_rasters) == 1) {
      pred_rasters <- append(pred_rasters, predicted_rasters)
    }

    # update checkpoint and save per-block tifs
    suffix <- gsub("raster_stack_|\\.tif$", "", fname)
    save_block_results(pred_rasters[[length(pred_rasters)]], lower_rasters[[length(lower_rasters)]], upper_rasters[[length(upper_rasters)]], output_cache, output_prefix, suffix)

    checkpoint$processed_files <- c(checkpoint$processed_files, fname)
    saveRDS(checkpoint, checkpoint_file)
    message("Saved checkpoint: ", checkpoint_file)
  }

  # save merged
  save_results(pred_rasters, lower_rasters, upper_rasters, output_cache, output_prefix)
}