script_args <- commandArgs(trailingOnly = FALSE)
script_file <- sub("--file=", "", script_args[grepl("--file=", script_args)])
project_dir <- if (length(script_file) > 0 && nchar(script_file) > 0) {
  normalizePath(dirname(script_file), mustWork = FALSE)
} else if (dir.exists("/home/rstudio/project/Week1")) {
  "/home/rstudio/project/Week1"
} else {
  getwd()
}

data_path <- file.path(project_dir, "data", "truck_manufacturing_defects_w1.csv")
output_dir <- file.path(project_dir, "plots_rstudio", "w1")

truck_defects <- read.csv(data_path)

if (!all(c("period", "value") %in% names(truck_defects))) {
  stop("Expected CSV columns: period,value")
}

truck_defects <- truck_defects[order(truck_defects$period), ]
defects_ts <- ts(truck_defects$value, start = min(truck_defects$period), frequency = 1)

if (!dir.exists(output_dir)) {
  dir.create(output_dir)
}

png(file.path(output_dir, "truck_defects_timeseries.png"), width = 900, height = 550)
plot(
  defects_ts,
  type = "o",
  pch = 16,
  col = "#1f77b4",
  xlab = "Period",
  ylab = "Daily average number of defects",
  main = "Truck Manufacturing Defects - Series W1"
)
grid()
dev.off()

png(file.path(output_dir, "truck_defects_correlogram.png"), width = 900, height = 550)
acf(
  defects_ts,
  lag.max = 20,
  main = "Correlogram of Truck Manufacturing Defects - Series W1",
  xlab = "Lag"
)
dev.off()

message("Loaded ", nrow(truck_defects), " observations from ", data_path)
message("Saved plots in ", output_dir)
