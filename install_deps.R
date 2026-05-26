# install_deps.R
# Install required R packages for ChinaForestSoilProperties-DSM

cran_pkgs <- c(
  "yaml",
  "caret",
  "ranger",
  "pls",
  "readr",
  "Cubist"
)

# For more advanced workflows (used e.g. by step_2_tuning.R, step_3_predict.R)
extra_pkgs <- c(
  "mlr3",
  "mlr3learners",
  "mlr3tuning",
  "mlr3filters",
  "mlr3verse",
  "data.table",
  "terra",
  "sf"
)

# All together
all_pkgs <- unique(c(cran_pkgs, extra_pkgs))

installed <- rownames(installed.packages())
for(pkg in all_pkgs) {
  if(!pkg %in% installed) {
    install.packages(pkg, dependencies = TRUE)
  }
}

cat("All required packages are installed.\n")