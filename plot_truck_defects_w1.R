args <- commandArgs(trailingOnly = FALSE)
file_arg <- "--file="
script_path <- sub(file_arg, "", args[grepl(file_arg, args)])
project_dir <- if (length(script_path) > 0) dirname(normalizePath(script_path)) else getwd()

data_path <- file.path(project_dir, "data", "truck_manufacturing_defects_w1.csv")
output_dir <- file.path(project_dir, "plots")

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
