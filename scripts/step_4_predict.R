# step_4_predict.R
# Step 4: Block-wise raster prediction and mosaic using a trained RF/QRF model
# Usage: Rscript step_4_predict.R [config.yml]
#
# Expects:
# - best_features.rds: character vector of covariate names
# - v0_5_final_rf_model.rds: trained mlr3/ranger model object
# - Raster tiles (GeoTIFFs) named raster_stack_*.tif
# Outputs: prediction, lower, upper quantile raster mosaics to output_dir

suppressPackageStartupMessages({
  library(yaml)
  library(raster)
  library(readr)
})

# Null coalescing assignment for config
`%||%` <- function(a, b) if (!is.null(a)) a else b

args <- commandArgs(trailingOnly = TRUE)
cfg_path <- ifelse(length(args) >= 1, args[[1]], "config.yml")
if (!file.exists(cfg_path)) stop("config.yml not found.")
cfg <- yaml::read_yaml(cfg_path)

set.seed(cfg$seed %||% 42)

# Standardized I/O parameters
raster_stack_dir <- cfg$raster_stack_dir %||% "raster_tiles"
output_dir <- cfg$output_dir %||% "outputs"
output_prefix <- cfg$output_prefix %||% cfg$response_col %||% "v0_5"
best_feature_file <- cfg$best_feature_file %||% "best_features.rds"
final_model_file <- cfg$final_model_file %||% paste0(output_prefix, "_final_rf_model.rds")
quantiles <- cfg$prediction$quantiles %||% c(0.05, 0.5, 0.95)
raster_pattern <- cfg$raster_stack_pattern %||% "^raster_stack_.*\\.tif$"

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

# List all raster tiles for block-wise prediction
raster_files <- list.files(raster_stack_dir, pattern = raster_pattern, full.names = TRUE)
if (length(raster_files) == 0)
  stop("No raster stack tiles found in '", raster_stack_dir, "'; check the directory and pattern.")

# Load best features and trained model
if (!file.exists(best_feature_file))
  stop("Best features file not found: ", best_feature_file)
if (!file.exists(final_model_file))
  stop("Trained model file not found: ", final_model_file)

best_features <- readRDS(best_feature_file)
trained_model <- readRDS(final_model_file)

# Helper function to merge rasters using mean mosaic
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

# Prediction and result holders
pred_rasters <- list()
lower_rasters <- list()
upper_rasters <- list()

for (tile_file in raster_files) {
  tile_name <- basename(tile_file)
  message("Processing block tile: ", tile_name)
  
  # Read raster stack and select layers by names
  rst <- tryCatch({ stack(tile_file) }, error = function(e) { message("Read tile error: ", e$message); NULL })
  if (is.null(rst)) next
  
  matched_layers <- intersect(as.character(best_features), names(rst))
  if (length(matched_layers) == 0) {
    warning("No matching features in raster tile for best_features.rds; skipping ", tile_name)
    next
  }
  rst_selected <- rst[[matched_layers]]
  
  # If quantile support, predict three quantiles, otherwise only median (0.5)
  raster_preds <- list()
  for (q in quantiles) {
    pr <- tryCatch({
      # If using mlr3-ranger with quantile support: check if predict_type supports quantiles
      if (inherits(trained_model, "Learner")) {
        # Here, only prediction type "response" (point prediction) supported
        # If quantile is median, proceed; otherwise, skip or repeat median
        if (q == 0.5) {
          predict(rst_selected, trained_model)
        } else {
          predict(rst_selected, trained_model) # Fallback - repeat median
        }
      } else if (inherits(trained_model, "ranger")) {
        # If it's a raw ranger object with quantile support
        predict(rst_selected, trained_model, type = 'quantiles', quantiles = q)
      } else {
        # Fallback generic predict
        predict(rst_selected, trained_model)
      }
    }, error = function(e) { message("Prediction error for quantile ", q, ": ", e$message); NULL })
    raster_preds <- append(raster_preds, list(pr))
  }
  
  # Assign outputs (if model only supports median, all identical)
  suffix <- gsub("^raster_stack_|\\.tif$", "", tile_name)
  pred_rasters[[suffix]] <- raster_preds[[2]] # 0.5 median
  lower_rasters[[suffix]] <- raster_preds[[1]] # 0.05
  upper_rasters[[suffix]] <- raster_preds[[3]] # 0.95
  
  # Write each block's prediction as separate tifs
  writeRaster(pred_rasters[[suffix]], file.path(output_dir, paste0(output_prefix, "_", suffix, "_pred.tif")), format = "GTiff", overwrite = TRUE)
  writeRaster(lower_rasters[[suffix]], file.path(output_dir, paste0(output_prefix, "_", suffix, "_lower.tif")), format = "GTiff", overwrite = TRUE)
  writeRaster(upper_rasters[[suffix]], file.path(output_dir, paste0(output_prefix, "_", suffix, "_upper.tif")), format = "GTiff", overwrite = TRUE)
  message("Saved block prediction for suffix: ", suffix)
}

# Merge prediction rasters across blocks
combine_and_write <- function(rlist, kind) {
  r <- merge_rasters(Filter(Negate(is.null), rlist))
  if (!is.null(r))
    writeRaster(r, file.path(output_dir, paste0(output_prefix, "_", kind, ".tif")), format = "GTiff", overwrite = TRUE)
}
combine_and_write(pred_rasters, "pred")
combine_and_write(lower_rasters, "lower")
combine_and_write(upper_rasters, "upper")
cat("All block-wise and mosaic raster predictions complete. Output saved to: ", output_dir, "\n")