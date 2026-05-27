# step2_FRFS.R
# Step 2: Parameterized Forward Recursive Feature Selection for harmonized DSM data
# Reads 'harmonized_soil.csv', runs feature selection on the target depth/interval, outputs selected features and importance.
# Usage: Rscript step2_FRFS.R [config.yml]

suppressPackageStartupMessages({
  library(caret)
  library(ranger)
  library(yaml)
})

# Null coalescing helper for defaults
`%||%` <- function(a, b) if (!is.null(a)) a else b

# --- Load config or defaults ---
args <- commandArgs(trailingOnly = TRUE)
cfg_path <- ifelse(length(args) >= 1, args[[1]], "config.yml")
cfg <- if (file.exists(cfg_path)) yaml::read_yaml(cfg_path) else list()

input_file  <- cfg$input_file %||% "harmonized_soil.csv"
output_dir  <- cfg$output_dir %||% "."
response_var <- cfg$response_var %||% "v0_5"   # <-- change this to your desired interval e.g., "v15_30"
n_features   <- cfg$n_features %||% 10
set.seed(cfg$seed %||% 666)

# --- Read harmonized data ---
data <- read.csv(input_file, stringsAsFactors = FALSE)
if (!(response_var %in% colnames(data))) stop(sprintf("Response variable '%s' not found in input file. Please check file or set response_var in config.", response_var))
if (!("ID" %in% names(data))) stop("Input file must contain 'ID' column.")

predictors <- setdiff(names(data), c("ID", response_var))
fitControl <- trainControl(method = "cv", number = 5)

# --- Fit Random Forest and select top features ---
rf_fit <- train(
  y = data[[response_var]],
  x = data[predictors],
  method = "ranger",
  importance = "permutation",
  trControl = fitControl,
  num.trees = cfg$num_trees %||% 500
)

importance <- varImp(rf_fit)$importance
importance <- importance[order(-importance$Overall), , drop=FALSE]
selected_features <- rownames(importance)[1:min(n_features, nrow(importance))]

# --- Output results ---
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
saveRDS(selected_features, file = file.path(output_dir, "best_features.rds"))
write.table(importance, file = file.path(output_dir, "FRFS_performance.txt"), sep = "\t", quote = FALSE, col.names = NA)

cat("Feature selection completed!\nResults saved in: ", output_dir, "\n")