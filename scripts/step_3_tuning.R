# step_3_tuning.R
# Step 3: Tuned Random Forest/Quantile RF modeling using mlr3
# Usage: Rscript step_3_tuning.R [config.yml]
#
# This version expects "harmonized_soil.csv" as input and uses "best_features.rds".
# It automatically uses the specified target column (default 'v0_5') as the response.
# Outputs model performance CSV and trained model RDS to output_dir.

suppressPackageStartupMessages({
  library(yaml)
  library(readr)
  library(mlr3)
  library(mlr3learners)
  library(mlr3tuning)
  library(paradox)
  library(dplyr)
})

# Helper for robust config values
`%||%` <- function(a, b) if (!is.null(a)) a else b

# --- Load config ---
args <- commandArgs(trailingOnly = TRUE)
cfg_path <- ifelse(length(args) >= 1, args[[1]], "config.yml")
if (!file.exists(cfg_path)) stop("config.yml not found.")
cfg <- yaml::read_yaml(cfg_path)

seed <- cfg$seed %||% 42
set.seed(seed)

input_file  <- cfg$input_file %||% "harmonized_soil.csv"
output_dir  <- cfg$output_dir %||% "outputs"
response_col <- cfg$response_col %||% "v0_5"
best_feature_file <- cfg$best_feature_file %||% "best_features.rds"
final_model_suffix <- cfg$final_model_suffix %||% "_final_rf_model.rds"
resampling_folds <- cfg$tuning$resampling_folds %||% 5
n_evals <- cfg$tuning$n_evals %||% 25
categorical_vars <- cfg$frfs$categorical_vars %||% c("FT","Geol","Geomor","Soil")

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

# --- Load data ---
df <- readr::read_csv(input_file, show_col_types = FALSE)
if (!(response_col %in% names(df)))
  stop(sprintf("Response variable '%s' not found in data columns.", response_col))

# Prepare features and y
if ("ID" %in% names(df)) df <- df[, setdiff(names(df), "ID")]
y <- df[[response_col]]
X <- df[, setdiff(names(df), response_col), drop = FALSE]

# Load best features
if (!file.exists(best_feature_file))
  stop(sprintf("Best features file '%s' not found.", best_feature_file))
best_features <- readRDS(best_feature_file)
X_sel <- X[, intersect(best_features, names(X)), drop = FALSE]
if (ncol(X_sel) == 0) stop("No selected features found in data.")

# Convert categorical columns to factors if present
for (cv in categorical_vars) {
  if (cv %in% names(X_sel)) X_sel[[cv]] <- as.factor(X_sel[[cv]])
}

# Train/test split (90/10)
set.seed(seed)
train_idx <- caret::createDataPartition(y, p = 0.9, list = FALSE)
train_df <- cbind(X_sel[train_idx, , drop = FALSE], y = y[train_idx])
test_df  <- cbind(X_sel[-train_idx, , drop = FALSE], y = y[-train_idx])

# ML task and learner
task_train <- TaskRegr$new("train", backend = train_df, target = "y")
learner <- lrn("regr.ranger", predict_type = "response")

# Parameter tuning bounds
n_features <- max(1, ncol(X_sel))
param_set <- ParamSet$new(list(
  ParamInt$new("mtry", lower = cfg$tuning$param_search$mtry$lower %||% 2, upper = cfg$tuning$param_search$mtry$upper %||% n_features),
  ParamInt$new("num.trees", lower = cfg$tuning$param_search$num.trees$lower %||% 100, upper = cfg$tuning$param_search$num.trees$upper %||% 500),
  ParamInt$new("min.node.size", lower = cfg$tuning$param_search$min.node.size$lower %||% 3, upper = cfg$tuning$param_search$min.node.size$upper %||% 20)
))

# Random search tuning
tuner <- tnr("random_search")
instance <- TuningInstanceSingleCrit$new(
  task = task_train,
  learner = learner,
  resampling = rsmp("cv", folds = resampling_folds),
  measure = msr("regr.rmse"),
  search_space = param_set,
  terminator = trm("evals", n_evals = n_evals)
)
tuner$optimize(instance)
best_params <- instance$result_learner_param_vals
cat("Best parameters found:\n")
print(best_params)

# Retrain with best parameters
learner$param_set$values <- best_params
learner$train(task_train)

# Evaluate train and test
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

# Save single performance CSV
performance <- data.frame(
  Response = response_col,
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

perf_file <- file.path(output_dir, paste0(response_col, "_optimized_performance.csv"))
readr::write_csv(performance, perf_file)
cat("Model performance written to:", perf_file, "\n")

# Optionally, save the final trained model
model_file <- file.path(output_dir, paste0(response_col, final_model_suffix))
saveRDS(learner, model_file)
cat("Final trained model saved to:", model_file, "\n")