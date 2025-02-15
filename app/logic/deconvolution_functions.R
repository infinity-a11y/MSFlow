# app/logic/deconvolution_functions.R

box::use(
  ggplot2,
  utils[read.table],
  shiny[showNotification],
  parallel[detectCores, makeCluster, parLapply, stopCluster],
  reticulate[use_python, py_config, py_run_string],
)

#' @export
deconvolute <- function(raw_dirs,
                        num_cores = detectCores() - 1,
                        startz = 1, endz = 50,
                        minmz = '', maxmz = '',
                        masslb = 5000, massub = 500000,
                        massbins = 10, peakthresh = 0.1,
                        peakwindow = 500, peaknorm = 1,
                        time_start = '', time_end = '') {

  # ensure python path and packages availability
  py_outcome <- tryCatch({
    use_python(py_config()$python, required = TRUE)
    TRUE
  }, error = function(e) {
    # showNotification(
    #   "Python modules could not be loaded. Aborting.",
    #   type = "error",
    #   duration = NULL
    # )
    FALSE
  })

  if (!py_outcome) {
    return()
  }

  # Deconvolution function for a single waters .raw
  process_single_dir <- function(waters_dir,
                                 startz, endz, minmz, maxmz,
                                 masslb, massub, massbins, peakthresh,
                                 peakwindow, peaknorm, time_start, time_end) {

    input_path <- gsub("\\\\", "/", waters_dir)

    # Function to properly format parameters for Python
    format_param <- function(x) {
      if (is.character(x) && x == "") {
        return("''")
      } else {
        return(as.character(x))
      }
    }

    # Create parameters string for Python
    params_string <- sprintf(
      '"startz": %s, "endz": %s, "minmz": %s, "maxmz": %s, "masslb": %s, "massub": %s, "massbins": %s, "peakthresh": %s, "peakwindow": %s, "peaknorm": %s, "time_start": %s, "time_end": %s',
      format_param(startz),
      format_param(endz),
      format_param(minmz),
      format_param(maxmz),
      format_param(masslb),
      format_param(massub),
      format_param(massbins),
      format_param(peakthresh),
      format_param(peakwindow),
      format_param(peaknorm),
      format_param(time_start),
      format_param(time_end)
    )

    reticulate::py_run_string(sprintf('
import sys
import unidec
import re

# Initialize UniDec engine
engine = unidec.UniDec()

# Convert Waters .raw to txt
input_file = r"%s"
engine.raw_process(input_file)
txt_file = re.sub(r"\\.raw$", "_rawdata.txt", input_file)
engine.open_file(txt_file)

# Parameters passed from R
params = {%s}

# Set configuration parameters
engine.config.startz = params["startz"]
engine.config.endz = params["endz"]
engine.config.minmz = params["minmz"]
engine.config.maxmz = params["maxmz"]
engine.config.masslb = params["masslb"]
engine.config.massub = params["massub"]
engine.config.massbins = params["massbins"]
engine.config.peakthresh = params["peakthresh"]
engine.config.peakwindow = params["peakwindow"]
engine.config.peaknorm = params["peaknorm"]
engine.config.time_start = params["time_start"]
engine.config.time_end = params["time_end"]

# Process and deconvolve the data
engine.process_data()
engine.run_unidec()
engine.pick_peaks()
', input_path, params_string))
  }

  # showNotification(paste0("Deconvolution initiated"),
  #                  type = "message", duration = NULL)

  # Process directories in parallel
  if(num_cores > 1) {
    cl <- makeCluster(detectCores() - 1)
    on.exit(stopCluster(cl))

    message(paste0(num_cores, " cores detected. Parallel processing started."))

    # Pass variables
    startz <- startz
    endz <- endz
    minmz <- minmz
    maxmz <- maxmz
    masslb <- masslb
    massub <- massub
    massbins <- massbins
    peakthresh <- peakthresh
    peakwindow <- peakwindow
    peaknorm <- peaknorm
    time_start <- time_start
    time_end <- time_end

    # Create wrapper function that includes all parameters
    process_wrapper <- function(dir) {
      process_single_dir(dir,
                         startz, endz,
                         minmz, maxmz,
                         masslb, massub,
                         massbins, peakthresh,
                         peakwindow, peaknorm,
                         time_start, time_end)
    }

    results <- parLapply(cl, raw_dirs, process_wrapper)

  } else {
    message(paste0(num_cores, " core(s) detected. Sequential processing started."))

    results <- lapply(raw_dirs, function(dir) {
      process_single_dir(dir,
                         startz, endz,
                         minmz, maxmz,
                         masslb, massub,
                         massbins, peakthresh,
                         peakwindow, peaknorm,
                         time_start, time_end)
    })
  }

  # Summarize results
  successful <- sum(sapply(results, function(x) !is.null(x)))
  failed <- length(results) - successful

  # showNotification("Deconvolution finalized", type = "message", duration = NULL)
  # message(sprintf(
  #   "\nProcessing complete:\n- Successfully processed: %d\n- Failed: %d",
  #   successful, failed))

  # return(results)
}

#' @export
plot_ms_spec <- function(waters_dir) {

  # Get results directories
  unidecfiles <- list.files(waters_dir, full.names = TRUE)

  # Get file
  mass_intensity <- grep("_mass\\.txt$", unidecfiles, value = TRUE)
  mass_data <- read.table(mass_intensity, sep = " ", header = TRUE)
  colnames(mass_data) <- c("mz", "intensity")

  plot(mass_data$mz, mass_data$intensity, type = "h",
       xlab = "Mass (Da)", ylab = "Intensity",
       main = "Deconvoluted Mass Spectrum",
       col = "blue", lwd = 3)
}

#' @export
create_384_plate_heatmap <- function(data) {
  # Expect data frame with columns: well_id (e.g., "A1"), value

  # Create plate layout coordinates
  rows <- LETTERS[1:16]
  cols <- 1:24
  plate_layout <- expand.grid(row = rows, col = cols)
  plate_layout$well_id <- paste0(plate_layout$row, plate_layout$col)

  # Merge data with plate layout
  plate_data <- merge(plate_layout, data, by = "well_id", all.x = TRUE)

  # Create the plot
  plate_plot <- ggplot2$ggplot(plate_data,
                               ggplot2$aes(x = col, y = row, fill = value)) +
    ggplot2$geom_tile(color = "black", linewidth = 0.1) +
    ggplot2$scale_y_discrete(limits = rev(rows)) +
    ggplot2$scale_x_continuous(
      breaks = 1:24,
      labels = 1:24,
      expand = c(0.01, 0.01)
    ) +
    ggplot2$scale_fill_gradient2(
      low = "white",
      mid = "yellow",
      high = "red",
      midpoint = mean(plate_data$value, na.rm = TRUE),
      na.value = "grey90"
    ) +
    ggplot2$coord_fixed() +
    ggplot2$theme_minimal() +
    ggplot2$theme(
      axis.text.x = ggplot2$element_text(size = 8, angle = 0),
      axis.text.y = ggplot2$element_text(size = 8),
      axis.title = ggplot2$element_blank(),
      panel.grid = ggplot2$element_blank(),
      plot.title = ggplot2$element_text(hjust = 0.5),
      plot.margin = ggplot2$margin(t = 10, r = 10, b = 10, l = 10, unit = "pt")
    )

  return(plate_plot)
}
