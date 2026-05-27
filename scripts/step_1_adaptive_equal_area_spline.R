# step1_adaptive_equal_area_spline.R
# Adaptive Equal-Area Spline for Soil Layer Standardization (Pipeline Step 1)
#
# Usage:
#   Rscript step1_adaptive_equal_area_spline.R [input.csv] [output.csv]
#
# Required columns: ID, Upper_depth, Lower_depth, Soilproperties

args <- commandArgs(trailingOnly = TRUE)
input_file  <- ifelse(length(args) >= 1, args[1], "rawdata.csv")
output_file <- ifelse(length(args) >= 2, args[2], "harmonized_soil.csv")

# ---- Load data ----
d_raw <- read.csv(input_file, header = TRUE, stringsAsFactors = FALSE)

required_cols <- c("ID", "Upper_depth", "Lower_depth", "Soilproperties")
actual_cols <- tolower(colnames(d_raw))
expected <- tolower(required_cols)
if (!all(expected %in% actual_cols)) {
  stop(sprintf("Input file must contain columns: %s", paste(required_cols, collapse = ", ")))
}

id         <- d_raw$ID
upperdepth <- as.numeric(d_raw$Upper_depth)
lowerdepth <- as.numeric(d_raw$Lower_depth)
soilvalue  <- as.numeric(d_raw$Soilproperties)
idProfile  <- unique(id)
numProfiles <- length(idProfile)

# ---- Complete profile horizon ----
hList <- list()
for (i in seq_along(idProfile)) {
  idx  <- which(id == idProfile[i])
  d1   <- d_raw[idx, ]
  idPr  <- as.character(d1$ID)
  uLim  <- as.numeric(d1$Upper_depth)
  lLim  <- as.numeric(d1$Lower_depth)
  soilVal <- as.numeric(d1$Soilproperties)
  newHorizon <- rep(0, length(idPr))
  Count1 <- length(idPr)
  if (Count1 == 1 && uLim[1] != 0)
    stop(sprintf("Single horizon and not surface: %s. Please delete manually.", idProfile[i]))
  if (Count1 > 1 && uLim[1] != 0) {
    soilValAdd <- if (Count1 >= 2 && uLim[2] == lLim[1])
      soilVal[1] + (soilVal[1] - soilVal[2]) / 4 else soilVal[1]
    soilValAdd <- max(soilValAdd, 0)
    idPr       <- c(idPr[1], idPr)
    uLim       <- c(0, uLim)
    lLim       <- c(uLim[1], lLim)
    soilVal    <- c(soilValAdd, soilVal)
    newHorizon <- c(1, newHorizon)
    Count1     <- Count1 + 1
  }
  k <- 1
  while (k < Count1) {
    if (uLim[k+1] != lLim[k]) {
      idPr       <- append(idPr, idPr[k], after = k)
      uLim       <- append(uLim, lLim[k], after = k)
      lLim       <- append(lLim, uLim[k+1], after = k)
      soilVal    <- append(soilVal, mean(soilVal[k:(k+1)], na.rm=TRUE), after = k)
      newHorizon <- append(newHorizon, 1, after = k)
      Count1     <- Count1 + 1
    } else {
      k <- k + 1
    }
  }
  if (any(uLim[-1] != lLim[-length(lLim)])) stop("Horizons still incomplete or data error!")
  hList[[i]] <- data.frame(
    ID          = idPr,
    Upper_depth = uLim,
    Lower_depth = lLim,
    Soilproperties = soilVal,
    added       = newHorizon,
    stringsAsFactors = FALSE
  )
}
hDf <- do.call(rbind, hList)

# ---- Define weighted interval calculation ----
generateLayerAvg <- function(horizonData, uDepth, lDepth) {
  uLim    <- as.numeric(horizonData$Upper_depth)
  lLim    <- as.numeric(horizonData$Lower_depth)
  soilVal <- as.numeric(horizonData$Soilproperties)
  n <- length(uLim)
  if (uDepth < 0 || lDepth < 0) return(NA_real_)
  if (uDepth >= lDepth) return(NA_real_)
  beginIdx <- which((uDepth >= uLim) & (uDepth < lLim))
  endIdx   <- which((lDepth > uLim) & (lDepth <= lLim))
  beginNum <- if (length(beginIdx) > 0) beginIdx[1] else n + 1
  endNum   <- if (length(endIdx) > 0) endIdx[1] else n + 1
  if (beginNum > n || endNum == 0) return(NA_real_)
  if (endNum == beginNum && endNum <= n) {
    return(soilVal[beginNum])
  }
  headerVal <- soilVal[beginNum] * (lLim[beginNum]-uDepth)/(lDepth-uDepth)
  tailVal   <- if (endNum <= n) soilVal[endNum]*(lDepth-uLim[endNum])/(lDepth-uDepth)
  else 0
  bodyVal   <- if (endNum - beginNum <= 1) 0 else {
    sum(soilVal[(beginNum+1):(endNum-1)] * 
          (lLim[(beginNum+1):(endNum-1)] - uLim[(beginNum+1):(endNum-1)])/(lDepth-uDepth), na.rm = TRUE)
  }
  out <- headerVal + tailVal + bodyVal
  if ((endNum > n) & ((lLim[n]-uDepth) < ((lDepth-uDepth)/5))) return(NA_real_)
  round(out, 2)
}

# ---- Define target intervals ----
uDepths <- c(0, 5, 15, 30, 60)
lDepths <- c(5, 15, 30, 60, 100)
layer_names <- mapply(function(u, l) sprintf("v%d_%d", u, l), uDepths, lDepths, USE.NAMES = FALSE)

userVal <- matrix(NA_real_, nrow = length(idProfile), ncol = length(uDepths))
for (i in seq_along(idProfile)) {
  hd <- hList[[i]]
  for (j in seq_along(uDepths)) {
    userVal[i, j] <- suppressWarnings(generateLayerAvg(hd, uDepths[j], lDepths[j]))
  }
}
res <- data.frame(ID = idProfile, userVal, stringsAsFactors = FALSE)
colnames(res)[-1] <- layer_names

# ---- Output --- (CSV for step2_FRFS input)
write.csv(res, output_file, row.names = FALSE)
cat(sprintf("\n[soilproperty_wa step1] Done! Output written to: %s\n", output_file))