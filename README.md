# ChinaForestSoilProperties-DSM — Forest Soil Properties Digital Soil Mapping (DSM)

**ChinaForestSoilProperties-DSM** is an R-based reproducible pipeline for mapping various forest soil properties (e.g., SOC, pH, total nitrogen, etc.) across China using sample-based Quantile Random Forest (QRF). The workflow achieves automated feature selection, model training, and block-wise raster prediction and mosaicking. All workflow parameters and file naming conventions are centrally controlled for maximum flexibility and reproducibility.

---

## Table of Contents

- Project name
- Quick start
- Data and file naming conventions
- Pipeline steps
- Configuration (`config.yml`)
- Outputs
- Reproducibility
- License
- Citation & Contact
- Notes

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

2. **Edit `config.yml` in the repository root** to specify your region, soil property, depth, directories, and other parameters.
   - Example fields:
     ```yaml
     region: "China"
     soil_property: "pH"
     depth: "05"
     input_dir: "./data"
     raster_stack_dir: "./raster_tiles"
     output_dir: "./outputs"
     seed: 666
     ```
   - Adjust other settings as needed for your environment.

3. **Install dependencies:**
   ```sh
   Rscript install_deps.R
   ```
   For stricter reproducibility, use `renv` or Docker.

3. **Run each pipeline step:**
   ```sh
   Rscript scripts/step_1_FRFS.R config.yml
   Rscript scripts/step_2_tuning.R config.yml
   Rscript scripts/step_3_predict.R config.yml
   ```
   Steps 1 (feature selection), 2 (model training & tuning), and 3 (block-wise raster prediction and mosaicking) are sufficient for core SOC/soil property mapping.  
   You may omit step 3 (variable importance and plotting) if not required.

---

## Data and file naming conventions

- **Input sample file:**  
  CSV format, named as  
  `<region>_<soilproperty><depth>_combined_data.csv`  
  _Example:_ `China_pH020_combined_data.csv`

- **CSV columns:**
  - The first column must be the response variable (soil property of interest), named `y`
  - Remaining columns: covariates/predictors (`X1, X2, ..., XN`)

- **Intermediate and output files:** All key files are automatically named using variables from the config.
  - Best features file: `<region>_<soilproperty><depth>_best_features.rds`
  - Model file: `<region>_<soilproperty><depth>_final_qrf_model.rds`
  - Performance log: `<region>_<soilproperty><depth>_FRFS_performance.txt`
  - Tuning results: `<region>_<soilproperty><depth>_optimized_performance.csv`
  - Block prediction rasters (tile/merged): `*_pred.tif`, `*_lower.tif`, `*_upper.tif`

- **Raster stacks:**  
  Pre-divided raster tiles in `raster_stack_dir/` (e.g. "raster_stack_001.tif"), with layer names matching covariates.

---

## Pipeline steps

1. **Feature Selection (FRFS)**
   - Script: `scripts/step_1_FRFS.R`
   - Method: Forward Recursive Feature Selection (RF, PLSR, or Cubist, configurable)
   - Output: best feature set (`*_best_features.rds`), performance log (`*_FRFS_performance.txt`)

2. **Hyperparameter Tuning & Model Training**
   - Script: `scripts/step_2_tuning.R`
   - Runs QRF (ranger) with parameter grid/random search, using best features from previous step
   - Output: model file (`*_final_qrf_model.rds`), tuning results (`*_optimized_performance.csv`), aggregated results as needed

3. **Block-wise Raster Prediction and Mosaicking**
   - Script: `scripts/step_3_predict.R`
   - Uses the trained model to predict soil property values on raster tiles and merge to full-coverage mosaics
   - Outputs: prediction rasters for selected quantiles (e.g., `*_pred.tif`, `*_lower.tif`, `*_upper.tif`)

---

## Configuration (`config.yml`)

All parameters are managed in a single `config.yml`.  
**Key fields include:**
- `region`, `soil_property`, `depth`
- `input_dir`, `raster_stack_dir`, `output_dir`
- FRFS settings (e.g., method, early_stop, categorical_vars)
- Model tuning search space (mtry, num.trees, min.node.size, n_evals)
- Prediction quantiles, checkpoint/cache settings
- `seed` (for reproducibility)
- Any script that generates file names or plots should use these variables for consistency

---

## Outputs

All outputs go to the `outputs/` folder (configurable):

- `<region>_<soilproperty><depth>_best_features.rds` — selected feature names
- `<region>_<soilproperty><depth>_final_qrf_model.rds` — trained QRF model object
- `<region>_<soilproperty><depth>_FRFS_performance.txt` — feature selection log
- `<region>_<soilproperty><depth>_optimized_performance.csv` — tuning/performance metrics
- `outputs/cache/` — per-tile and merged prediction TIFFs: `*_pred.tif`, `*_lower.tif`, `*_upper.tif`
- `outputs/sessionInfo.txt` — full R session info for reproducibility

---

## Reproducibility

- **Random seed** is controlled by `seed` in `config.yml`.
- Use `renv.lock` or Docker to freeze package versions (recommended).
- For peer review, include:
  - Your `outputs/sessionInfo.txt`
  - The exact `config.yml` used
  - An example input CSV (structure only is sufficient) or a filled `data/metadata_template.md` (if provided)

---

## License

A suitable open-source license is required (MIT or Apache-2.0 recommended).  
Add your `LICENSE` file to the repository root.

---

## Citation & Contact

If you use this code in your research, please cite the associated publication (add DOI once available) and credit the repository as follows:
- Project: SinoForestSoilAtlas
- Author / Contact: cjz-ux (see repository profile or AUTHOR file)

---

## Notes

- All intermediate files (`*_best_features.rds`, `*_final_qrf_model.rds`, etc.) are generated by the pipeline —  
  if distributing code only, provide clear metadata templates and instructions.
- Raster stacks **must** be pre-tiled and spatially aligned; the prediction script operates on user-provided blocks (e.g., `raster_stack_001.tif`).
- If not yet present, please add `data/metadata_template.md` or a blank example CSV to help users prepare their data structure.
