# ChinaForestSoilProperties-DSM — Forest Soil Properties Digital Soil Mapping Pipeline

**ChinaForestSoilProperties-DSM** is a reproducible R-based pipeline for digital soil mapping (DSM) of forest soil properties (e.g., pH, SOC, N, P, K) across China. The workflow is fully automated, performs feature selection, model training, and block-wise raster prediction and mosaicking. All configuration and file management is handled centrally for reproducibility and flexibility.

---

## Table of Contents

- [Project name](#project-name)
- [Quick start](#quick-start)
- [Data & file naming conventions](#data--file-naming-conventions)
- [Pipeline steps](#pipeline-steps)
- [Configuration (`config.yml`)](#configuration-configyml)
- [Outputs](#outputs)
- [Reproducibility](#reproducibility)
- [License](#license)
- [Citation & Contact](#citation--contact)
- [Notes](#notes)

---

## Project name

**ChinaForestSoilProperties-DSM**

---

## Quick start

1. **Clone the repository:**
   ```sh
   git clone <repo-url>
   cd <repo>
   ```

2. **Edit `config.yml`**  
   - Open `config.yml` in the repository root and set these parameters according to your application:
     ```yaml
     region: "China"
     soil_property: "pH"
     depth: "05"
     input_dir: "data"
     raster_stack_dir: "Block/Forests_Raster_stack_item"
     output_dir: "outputs"
     output_prefix: "v0_5"
     response_col: "v0_5"
     seed: 42
     ```
   - All file naming, feature/model selection, and target soil property settings are controlled via `config.yml`.

3. **Install R dependencies:**
   ```sh
   Rscript install_deps.R
   ```
   For absolute reproducibility, optionally use `renv::restore()`  
   or build/run in a Docker container.

4. **Run each pipeline step in sequence:**
   ```sh
   # Step 1: Harmonize soil profiles
   Rscript scripts/step1_adaptive_equal_area_spline.R rawdata.csv data/harmonized_soil.csv

   # Step 2: Feature Selection
   Rscript scripts/step2_FRFS.R config.yml

   # Step 3: Model Tuning & Training
   Rscript scripts/step_3_tuning.R config.yml

   # Step 4: Block-wise Raster Prediction & Mosaicking
   Rscript scripts/step_4_predict.R config.yml
   ```

   - After each step, key results are automatically named and organized as specified in `config.yml`.
   - No manual file renaming or intervention is required as long as you follow the config.

---

## Data & file naming conventions

- **Sample data CSV:**  
  Your (raw) profile data, e.g., `rawdata.csv`.  
  Must contain at least: `ID`, `Upper_depth`, `Lower_depth`, `Soilproperties`.

- **Harmonized soil table:**  
  Produced by step 1 as `harmonized_soil.csv` (see `input_dir`/`combined_pattern` in config).

- **Feature/model and prediction files:**  
  - `best_features.rds`: List of predictor names, output of step 2, input to 3 & 4.
  - `v0_5_final_rf_model.rds`: Trained model for your chosen target, output by step 3.
  - Outputs are always named using `output_prefix` and target info (e.g. `v0_5_pred.tif`) as specified in `config.yml`.

- **Raster stacks:**  
  Directory: as specified by `raster_stack_dir` (e.g., `Block/Forests_Raster_stack_item`).  
  Files: e.g., `raster_stack_001.tif`, each containing multiple predictor layers matching your features.

---

## Pipeline steps

1. **Profile harmonization**  
   - Script: `scripts/step1_adaptive_equal_area_spline.R`
   - Input: e.g., `rawdata.csv`.
   - Output: `harmonized_soil.csv`.

2. **Feature Selection (FRFS)**  
   - Script: `scripts/step2_FRFS.R`
   - Settings: Controlled by `frfs` section in config.
   - Output: `best_features.rds`, performance log.

3. **Model Tuning & Training**  
   - Script: `scripts/step_3_tuning.R`
   - Uses: Only features listed in `best_features.rds`.
   - Output: `v0_5_final_rf_model.rds`, tuning metrics.

4. **Block-wise Raster Prediction & Mosaicking**  
   - Script: `scripts/step_4_predict.R`
   - Predicts values for each raster stack, merges to create final mosaics.
   - Output: `{output_prefix}_pred.tif`, `{output_prefix}_lower.tif`, `{output_prefix}_upper.tif` in `outputs/cache/`.

---

## Configuration (`config.yml`)

All steps, file names, and parameters are controlled by `config.yml`:

```yaml
region: "China"
soil_property: "pH"
depth: "05"
seed: 42

input_dir: "data"
output_dir: "outputs"
raster_stack_dir: "Block/Forests_Raster_stack_item"
output_prefix: "v0_5"
response_col: "v0_5"
combined_pattern: "harmonized_soil.csv"
best_feature_file: "best_features.rds"
final_model_file: "v0_5_final_rf_model.rds"
raster_stack_pattern: "^raster_stack_.*\\.tif$"

frfs:
  method: "rf"
  early_stop: true
  rf_num_trees: 500
  cv_folds: 5
  categorical_vars:
    - FT
    - Geol
    - Geomor
    - Soil

tuning:
  resampling_folds: 5
  n_evals: 25
  param_search:
    mtry:
      lower: 2
      upper: null
    num.trees:
      lower: 100
      upper: 500
    min.node.size:
      lower: 3
      upper: 20

prediction:
  quantiles: [0.05, 0.5, 0.95]
  cache_dir: "outputs/cache"
  checkpoint_suffix: "_checkpoint.rds"
```

---

## Outputs

All output files and results will be placed in `outputs/` (or as specified):

- `best_features.rds` — selected feature list
- `v0_5_final_rf_model.rds` — final trained (quantile) random forest model
- `{output_prefix}_FRFS_performance.txt` — feature selection log
- `{output_prefix}_optimized_performance.csv` — model evaluation metrics
- `outputs/cache/` — block-wise and merged prediction TIFFs:
  - `v0_5_pred.tif`
  - `v0_5_lower.tif`
  - `v0_5_upper.tif`
- `sessionInfo.txt` — session/package info (recommended for reviews)

---

## Reproducibility

- Pipeline seed: controlled via `seed` in config.
- All parameters, patterns, and paths are controlled centrally.
- Use `install_deps.R` for dependency setup.
- For strict reproducibility: use `renv` or Docker.

---

## License

MIT (suggested) or another OSI-approved open-source license.  
Include a `LICENSE` file.

---

## Citation & Contact

If you use this pipeline for scientific research, please cite:  
- ChinaForestSoilProperties-DSM  
- Author: cjz-ux (see repository profile or AUTHOR file)

---

## Notes

- Only `config.yml` needs to be changed to alter region, property, depth, or outputs.
- Input raster stacks must have layers matching selected features.
- All key files are produced automatically and named consistently.
- Example metadata or data structure templates are provided in the repository if needed.