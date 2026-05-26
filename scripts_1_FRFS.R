# 1_FRFS.R
# Parameterized Forward Recursive Feature Selection (FRFS) script
# Usage: Rscript scripts/1_FRFS.R [path/to/config.yml]
#
# The script defines FRFS() and batch_process_files() and saves best_features .rds and RMSE tables.
# It reads configuration from config.yml (YAML). If not provided, uses default values.

suppressPackageStartupMessages({
  library(yaml)
  library(caret)
  library(ranger)
  library(pls)
  library(plsVarSel)
  library(Cubist)
  library(readr)
})

# --- helper: load config ---
args <- commandArgs(trailingOnly = TRUE)
cfg_path <- ifelse(length(args) >= 1, args[[1]], "config.yml")
if (!file.exists(cfg_path)) {
  stop("config.yml not found. Provide path as first argument or place config.yml in project root.")
}
cfg <- yaml::read_yaml(cfg_path)

seed <- cfg$seed %||% 666
set.seed(seed)

input_dir <- cfg$input_dir %||% "data"
output_dir <- cfg$output_dir %||% "outputs"
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

# FRFS function
FRFS <- function(data, var.res, method = cfg$frfs$method %||% "rf", early.stop = cfg$frfs$early_stop %||% TRUE) {
  # data: data.frame containing response and predictors
  # var.res: name of response column (string)
  # method: "rf", "plsr", "cubist"
  # Returns list(selected.variables, RMSE.results)
  require(caret); require(ranger); require(pls); require(plsVarSel); require(Cubist)
  if (!method %in% c("rf", "plsr", "cubist")) stop("method must be one of 'rf','plsr','cubist'")
  if (!var.res %in% names(data)) stop("Response variable not found in data.")

  col.var.res <- which(colnames(data) == var.res)
  var.exp <- colnames(data)[-col.var.res]

  # categorical variables from config
  categorical_vars <- cfg$frfs$categorical_vars %||% c("FT","Geol","Geomor","Soil")
  for (var in categorical_vars) {
    if (var %in% colnames(data)) data[[var]] <- as.factor(data[[var]])
  }

  set.seed(seed)
  if (method == "rf") {
    rf.temp <- ranger(x = data[, -col.var.res], y = data[, col.var.res], num.trees = cfg$frfs$rf_num_trees %||% 500, importance = "permutation")
    vip <- as.data.frame(rf.temp$variable.importance)
    colnames(vip) <- "importance"
    vip$feature <- rownames(vip)
    rownames(vip) <- NULL
    vip_df <- vip[order(-vip$importance), , drop = FALSE]
    vip <- setNames(as.data.frame(vip_df$importance), vip_df$feature)
  } else if (method == "plsr") {
    formula <- as.formula(paste0(var.res, "~", paste(var.exp, collapse = "+")))
    plsr.temp <- mvr(formula, data = data, ncomp = 20, validation = "CV")
    # safe selection of component
    rmse_vals <- RMSEP(plsr.temp)$val
    # try to find the proper structure
    # fallback: use first non-NA comp
    opt_comp <- tryCatch({
      which.min(rmse_vals[1, , drop = TRUE]) - 1
    }, error = function(e) 1)
    vip_vals <- VIP(plsr.temp, opt_comp, dim(plsr.temp$coef)[1])
    vip <- data.frame(vip = vip_vals)
    rownames(vip) <- var.exp
    colnames(vip) <- "importance"
    vip <- as.data.frame(vip)
  } else {
    cub.temp <- cubist(x = data[, -col.var.res], y = data[, col.var.res])
    # Cubist object structure can vary; attempt to get variable usage or importance-like metric
    vip <- tryCatch({
      if (!is.null(cub.temp$usage)) {
        usage <- cub.temp$usage
        # usage might have variable names in row/colnames
        if (is.matrix(usage) || is.data.frame(usage)) {
          # sum rows to make a ranking
          imp <- rowSums(abs(as.matrix(usage)))
          names(imp) <- rownames(usage)
          as.data.frame(imp)
        } else {
          # fallback
          data.frame(importance = unlist(usage))
        }
      } else {
        data.frame(importance = rep(1, length(var.exp)), row.names = var.exp)
      }
    }, error = function(e) {
      data.frame(importance = rep(1, length(var.exp)), row.names = var.exp)
    })
    colnames(vip) <- "importance"
  }

  # initialize chosen variables with the top importance
  if (is.data.frame(vip)) {
    importance_vec <- as.numeric(vip[,1])
    names(importance_vec) <- rownames(vip)
    var.choose <- names(importance_vec)[which.max(importance_vec)]
  } else {
    var.choose <- names(vip)[which.max(unlist(vip))]
  }
  var.left <- setdiff(var.exp, var.choose)

  fitControl <- trainControl(method = "cv", number = cfg$frfs$cv_folds %||% 5)
  RMSE.all <- data.frame(No.var = seq_along(var.exp), RMSE = NA_real_)
  RMSE.all[1, "No.var"] <- 1

  # fit initial model
  tune_and_fit <- function(var_set) {
    formula <- as.formula(paste0(var.res, "~", paste(var_set, collapse = "+")))
    if (method == "rf") {
      Grid <- expand.grid(mtry = seq(1, length(var_set), 1), min.node.size = 5, splitrule = "variance")
      model_name <- "ranger"
    } else if (method == "plsr") {
      Grid <- expand.grid(ncomp = seq(1, min(length(var_set), 20), 1))
      model_name <- "pls"
    } else {
      Grid <- expand.grid(committees = 1, neighbors = 0)
      model_name <- "cubist"
    }
    suppressWarnings({
      model.temp <- train(formula, data = data, method = model_name, trControl = fitControl, tuneGrid = Grid)
    })
    return(min(model.temp$results$RMSE, na.rm = TRUE))
  }

  RMSE.all[1, "RMSE"] <- tune_and_fit(var.choose)

  # iterative forward selection
  for (iter in (length(var.choose)+1):length(var.exp)) {
    RMSE.temp <- data.frame(Var = var.left, RMSE = NA_real_)
    for (i in seq_along(var.left)) {
      var.test <- c(var.choose, var.left[i])
      RMSE.temp$RMSE[i] <- tryCatch({
        set.seed(seed)
        tune_and_fit(var.test)
      }, error = function(e) {
        NA_real_
      })
    }
    if (all(is.na(RMSE.temp$RMSE))) break
    best_idx <- which.min(RMSE.temp$RMSE)
    if (RMSE.temp$RMSE[best_idx] < min(RMSE.all$RMSE, na.rm = TRUE)) {
      var.choose <- c(var.choose, RMSE.temp$Var[best_idx])
      var.left <- setdiff(var.exp, var.choose)
      RMSE.all[length(var.choose), "RMSE"] <- RMSE.temp$RMSE[best_idx]
    } else {
      if (!is.null(early.stop) && early.stop == TRUE) {
        RMSE.all[length(var.choose)+1, "RMSE"] <- min(RMSE.temp$RMSE, na.rm = TRUE)
        break
      } else {
        var.choose <- c(var.choose, RMSE.temp$Var[best_idx])
        var.left <- setdiff(var.exp, var.choose)
        RMSE.all[length(var.choose), "RMSE"] <- RMSE.temp$RMSE[best_idx]
      }
    }
  }

  return(list(selected.variables = var.choose, RMSE.results = RMSE.all))
}

# Batch processing using config paths
batch_process_files <- function(input_dir = input_dir, output_dir = output_dir, var_res_name = "y", method = NULL, early_stop = NULL) {
  files <- list.files(input_dir, pattern = cfg$combined_pattern %||% "_combined_data.csv$", full.names = TRUE)
  if (length(files) == 0) {
    message("No combined CSV files found in ", input_dir)
    return(invisible(NULL))
  }
  for (f in files) {
    message("Processing ", f)
    data <- tryCatch({ readr::read_csv(f, show_col_types = FALSE) }, error = function(e) { message("Read error: ", e$message); return(NULL) })
    if (is.null(data)) next

    res_name <- ifelse(var_res_name %in% names(data), var_res_name, names(data)[1])
    res_name <- var_res_name # user mandated format: first column is response called 'y'
    if (!res_name %in% names(data)) {
      # try to alias: first column is response
      names(data)[1] <- var_res_name
      res_name <- var_res_name
    }

    result <- FRFS(data = data, var.res = res_name, method = method %||% cfg$frfs$method %||% "rf", early.stop = early_stop %||% cfg$frfs$early_stop %||% TRUE)
    base <- tools::file_path_sans_ext(basename(f))
    # base trimming to first two underscore parts if needed
    parts <- unlist(strsplit(base, "_"))
    if (length(parts) >= 2) base_short <- paste(parts[1:2], collapse = "_") else base_short <- base
    rds_file <- file.path(output_dir, paste0(base_short, cfg$best_features_suffix %||% "_best_features.rds"))
    txt_file <- file.path(output_dir, paste0(base_short, "_FRFS_performance.txt"))
    saveRDS(result$selected.variables, rds_file)
    write.table(result$RMSE.results, file = txt_file, sep = "\t", row.names = FALSE, col.names = TRUE)
    message("Saved best features to: ", rds_file)
    message("Saved FRFS performance to: ", txt_file)
  }
}

# If invoked as a script, run batch with defaults
if (interactive() == FALSE) {
  # allow optional args: input_dir output_dir
  if (length(args) >= 2) {
    input_dir <- args[[2]]
    if (length(args) >= 3) output_dir <- args[[3]]
  }
  batch_process_files(input_dir = input_dir, output_dir = output_dir, var_res_name = "y")
}