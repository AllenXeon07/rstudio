# Package GSTAR monthly split experiments. Run: Rscript Week2/gstar_monthly_experiments.R
script <- sub("--file=", "", commandArgs(trailingOnly = FALSE)[grepl("--file=", commandArgs(trailingOnly = FALSE))])
root <- if (length(script)) dirname(normalizePath(script[1], mustWork = FALSE)) else if (dir.exists("/home/rstudio/project/Week2")) "/home/rstudio/project/Week2" else getwd()
source(file.path(root, "gstar_monthly_experiments_common.R"))
run_monthly_gstar_experiments("package")
