# 2_tuning.R
# Parameterized QRF / Random Forest tuning script using mlr3
# Usage: Rscript scripts/2_tuning.R [path/to/config.yml]
#
# Expects *_combined_data.csv in input_dir. Expects best_features.rds to exist for each data file
# Outputs per-file optimized_performance CSV into output_dir (or input_dir if not specified).

suppressPackageStartupMessages({
  library(yaml)
  library(readr)
  library(mlr3)
  library(mlr3learners)
  library(mlr3tuning)
  library(paradox)
  library(dplyr)
})

# --- load config ---
args <- commandArgs(trailingOnly = TRUE)
cfg_path <- ifelse(length(args) >= 1, args[[1]], "config.yml")
if (!file.exists(cfg_path)) stop("config.yml not found.")
cfg <- yaml::read_yaml(cfg_path)

seed <- cfg$seed %||% 666
set.seed(seed)

input_dir <- cfg$input_dir %||% "data"
output_dir <- cfg$output_dir %||% "outputs"
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

# list combined data files
data_files <- list.files(input_dir, pattern = cfg$combined_pattern %||% "_combined_data.csv$", full.names = TRUE)
if (length(data_files) == 0) {
  message("No combined data files found in ", input_dir)
  quit(status = 0)
}

# ensure mlr3 ranger learner available
if (!"regr.ranger" %in% mlr_learners$keys()) {
  message("Registering ranger learner...")
  mlr3learners::install_learners("regr.ranger")
}

for (file_path in data_files) {
  message("Processing file: ", file_path)
  df <- readr::read_csv(file_path, show_col_types = FALSE)
  # assume first column is response 'y' per your repo standard
  if (!(names(df)[1] == "y")) names(df)[1] <- "y"
  y <- df$y
  X <- df[, setdiff(names(df), "y"), drop = FALSE]

  # load best features rds (expected in same folder or output_dir)
  base <- tools::file_path_sans_ext(basename(file_path))
  bf_candidates <- c(
    file.path(input_dir, paste0(base, cfg$best_features_suffix %||% "_best_features.rds")),
    file.path(output_dir, paste0(base, cfg$best_features_suffix %||% "_best_features.rds")),
    file.path(input_dir, paste0(gsub("_combined_data$", "", base), cfg$best_features_suffix %||% "_best_features.rds"))
  )
  bf_file <- NULL
  for (c in bf_candidates) if (file.exists(c)) { bf_file <- c; break }
  if (is.null(bf_file)) {
    message("Best features file not found for ", base, ". Skipping tuning for this file.")
    next
  }
  best_features <- readRDS(bf_file) %>% as.character()
  X_sel <- X[, intersect(best_features, names(X)), drop = FALSE]
  if (ncol(X_sel) == 0) {
    message("No features selected for ", base, ". Skipping.")
    next
  }

  # handle categorical conversion if needed
  categorical_vars <- cfg$frfs$categorical_vars %||% c("FT","Geol","Geomor","Soil")
  for (cv in categorical_vars) {
    if (cv %in% names(X_sel)) X_sel[[cv]] <- as.factor(X_sel[[cv]])
  }

  # train/test split (90/10)
  set.seed(seed)
  train_idx <- caret::createDataPartition(y, p = 0.9, list = FALSE)
  train_df <- cbind(X_sel[train_idx, , drop = FALSE], y = y[train_idx])
  test_df  <- cbind(X_sel[-train_idx, , drop = FALSE], y = y[-train_idx])

  # mlr3 task and learner
  task_train <- TaskRegr$new("train", backend = train_df, target = "y")
  learner <- lrn("regr.ranger", predict_type = "response")

  # parameter bounds
  n_features <- max(1, ncol(X_sel))
  p_mtry_upper <- ifelse(is.null(cfg$tuning$param_search$mtry$upper), n_features, cfg$tuning$param_search$mtry$upper)
  param_set <- ParamSet$new(list(
    ParamInt$new("mtry", lower = cfg$tuning$param_search$mtry$lower %||% 2, upper = p_mtry_upper),
    ParamInt$new("num.trees", lower = cfg$tuning$param_search$num.trees$lower %||% 100, upper = cfg$tuning$param_search$num.trees$upper %||% 1500),
    ParamInt$new("min.node.size", lower = cfg$tuning$param_search$min.node.size$lower %||% 3, upper = cfg$tuning$param_search$min.node.size$upper %||% 50)
  ))

  # tuning
  tuner <- tnr("random_search")
  instance <- TuningInstanceSingleCrit$new(
    task = task_train,
    learner = learner,
    resampling = rsmp("cv", folds = cfg$tuning$resampling_folds %||% 10),
    measure = msr("regr.rmse"),
    search_space = param_set,
    terminator = trm("evals", n_evals = cfg$tuning$n_evals %||% 50)
  )
  tuner$optimize(instance)
  best_params <- instance$result_learner_param_vals
  message("Best params for ", base, ": ", paste(names(best_params), best_params, sep = "=", collapse = ", "))

  # set params and train on training set
  learner$param_set$values <- best_params
  learner$train(task_train)

  # evaluate on training and hold-out test
  pred_train <- learner$predict(task_train)$response
  train_mae <- mean(abs(pred_train - train_df$y))
  train_rmse <- sqrt(mean((pred_train - train_df$y)^2))
  train_r2 <- cor(train_df$y, pred_train)^2
  train_me <- mean(pred_train - train_df$y)
  train_mec <- 1 - sum((pred_train - train_df$y)^2) / sum((train_df$y - mean(train_df$y))^2)

  task_test <- TaskRegr$new("test", backend = test_df, target = "y")
  pred_test <- learner$predict(task_test)$response
  test_mae <- mean(abs(pred_test - test_df$y))
  test_rmse <- sqrt(mean((pred_test - test_df$y)^2))
  test_r2 <- cor(test_df$y, pred_test)^2
  test_me <- mean(pred_test - test_df$y)
  test_mec <- 1 - sum((pred_test - test_df$y)^2) / sum((test_df$y - mean(test_df$y))^2)

  optimized_performance <- data.frame(
    Region = NA_character_,
    Response = NA_character_,
    Depth = NA_character_,
    Best_mtry = best_params$mtry %||% NA_integer_,
    Best_num.trees = best_params$num.trees %||% NA_integer_,
    Best_min.node.size = best_params$min.node.size %||% NA_integer_,
    Train_MAE = train_mae,
    Train_RMSE = train_rmse,
    Train_R2 = train_r2,
    Train_ME = train_me,
    Train_MEC = train_mec,
    Test_MAE = test_mae,
    Test_RMSE = test_rmse,
    Test_R2 = test_r2,
    Test_ME = test_me,
    Test_MEC = test_mec
  )

  out_csv <- file.path(output_dir, paste0(base, "_optimized_performance.csv"))
  readr::write_csv(optimized_performance, out_csv)
  message("Wrote optimized performance to: ", out_csv)

  # Optionally save a final model object (trained on full data) for predictions
  # Train final model on the full dataset using best params
  task_full <- TaskRegr$new("full", backend = cbind(X_sel, y = y), target = "y")
  final_learner <- lrn("regr.ranger", predict_type = "response")
  final_learner$param_set$values <- best_params
  final_learner$train(task_full)
  model_file <- file.path(output_dir, paste0(base, cfg$final_model_suffix %||% "_final_qrf_model.rds"))
  saveRDS(final_learner, model_file)
  message("Saved final model to: ", model_file)
}

# After loop: optionally aggregate all results
opt_files <- list.files(output_dir, pattern = "_optimized_performance.csv$", full.names = TRUE)
if (length(opt_files) > 0) {
  combined <- lapply(opt_files, readr::read_csv, show_col_types = FALSE) %>% bind_rows(.id = "source")
  readr::write_csv(combined, file.path(output_dir, "total_optimized_model_results.csv"))
  message("Aggregated optimized results to total_optimized_model_results.csv")
}