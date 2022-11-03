# This file is part of the ipumsr R package created by IPUMS.
# For copyright and licensing information, see the NOTICE and LICENSE files
# in this project's top-level directory, and also on-line at:
#   https://github.com/ipums/ipumsr

#' Read data from an NHGIS extract
#'
#' Reads a dataset downloaded from the NHGIS extract system. Relies on csv files
#' (with or without the extra header row).
#'
#' @return \code{read_nhgis} returns a \code{tbl_df} with only the tabular data,
#' \code{read_nhgis_sf} returns a \code{sf} object with data and the shapes, and
#' \code{read_nhgis_sp} returns a \code{SpatialPolygonsDataFrame} with data and
#' shapes.
#' @param data_file Filepath to the data (either the .zip file directly
#'   downloaded from the website, the path to the unzipped folder, or
#'   the path to the unzipped .csv file directly).
#' @param shape_file Filepath to the shape files (either the .zip
#'   file directly downloaded from the website, or the path to the unzipped
#'   folder, or the unzipped .shp file directly).
#' @param data_layer For .zip extracts with multiple datasets, the name of the
#'   data to load. Accepts a character vector specifying the file name, or
#'  \code{\link{dplyr_select_style}} conventions. Data layer must uniquely identify
#'  a dataset.
#' @param shape_layer (Defaults to using the same value as data_layer) Specification
#'   of which shape files to load using the same semantics as \code{data_layer}. Can
#'   load multiple shape files, which will be combined.
#' @param shape_encoding The text encoding to use when reading the shape file. Typically
#'   the defaults should read the data correctly, but for some extracts you may need
#'   to set them manually, but if funny characters appear in your data, you may need
#'   to. Defaults to "latin1" for NHGIS.
#' @param verbose Logical, indicating whether to print progress information to
#'   console.
#' @param var_attrs Variable attributes to add from the codebook, defaults to
#'   adding all (val_labels, var_label and var_desc). See
#'   \code{\link{set_ipums_var_attributes}} for more details.
#' @examples
#' csv_file <- ipums_example("nhgis0707_csv.zip")
#' shape_file <- ipums_example("nhgis0707_shape_small.zip")
#'
#' data_only <- read_nhgis(csv_file)
#'
#' # If sf package is availble, can load as sf object
#' if (require(sf)) {
#'   sf_data <- read_nhgis_sf(csv_file, shape_file)
#' }
#'
#' # If sp package is available, can load as SpatialPolygonsDataFrame
#' if (require(rgdal) && require(sp)) {
#'   sp_data <- read_nhgis_sp(csv_file, shape_file)
#' }
#'
#' @family ipums_read
#' @export
read_nhgis <- function(data_file,
                       data_layer = NULL,
                       verbose = TRUE,
                       var_attrs = c("val_labels", "var_label", "var_desc"),
                       ...) {

  data_layer <- enquo(data_layer)

  custom_check_file_exists(data_file)

  if (file_is_zip(data_file)) {
    files <- unzip(data_file, list = TRUE)$Name
    cb_ddi_info <- try(
      read_ipums_codebook(data_file, !!data_layer),
      silent = TRUE
    )
  } else if (file_is_dir(data_file)) {
    files <- list.files(data_file)
    cb_ddi_info <- try(
      read_ipums_codebook(data_file, !!data_layer),
      silent = TRUE
    )
  } else {
    files <- list.files(dirname(data_file))
    # If direct file path provided, look in parent directory for codebook
    cb_ddi_info <- try(
      read_ipums_codebook(dirname(data_file)),
      silent = TRUE
    )
  }

  if (inherits(cb_ddi_info, "try-error")) {
    cb_ddi_info <- NHGIS_EMPTY_DDI
  }

  # Specify encoding (assuming all nhgis extracts are ISO-8859-1 eg latin1
  # because an extract with county names has n with tildes and so is can
  # be verified as ISO-8859-1)
  # TODO: I assume this is supposed to be `file_encoding` not `encoding`?
  # Check.
  cb_ddi_info$file_encoding <- "ISO-8859-1"

  # TODO: reconsider custom_cat formatting.
  # TODO: Conditions should be displayed when loading package?
  if (verbose) custom_cat(short_conditions_text(cb_ddi_info))

  # Read data
  if (verbose) cat("\n\nReading data file...\n")
  extract_locale <- ipums_locale(cb_ddi_info$file_encoding)

  # TODO: should check this on invalid file structures--i.e.
  # dirs with no csvs or dat files, etc.
  file_is_csv <- any(purrr::map_lgl(files, ~tools::file_ext(.x) == "csv"))

  # TODO: readr progress currently does not responsd to local verbose arg
  # TODO: readr show_col_types does not repsond to local verbose arg.
  # May remove verbose arg.
  if (file_is_csv) {
    data <- read_nhgis_csv(data_file, data_layer = !!data_layer, ...)
  } else {
    data <- read_nhgis_fwf(data_file, data_layer = !!data_layer, ...)
  }

  data <- set_ipums_var_attributes(data, cb_ddi_info$var_info, var_attrs)

  data

}
#' @rdname read_nhgis
#' @export
read_nhgis_sf <- function(
  data_file,
  shape_file,
  data_layer = NULL,
  shape_layer = data_layer,
  shape_encoding = "latin1",
  verbose = TRUE,
  var_attrs = c("val_labels", "var_label", "var_desc")

) {
  data <- read_nhgis(data_file, !!enquo(data_layer), verbose)

  shape_layer <- enquo(shape_layer)
  if (quo_text(shape_layer) == "data_layer") shape_layer <- data_layer
  if (verbose) cat("Reading geography...\n")

  sf_data <- read_ipums_sf(
    shape_file, !!shape_layer, verbose = verbose, encoding = shape_encoding
  )

  # Only join on vars that are in both and are called "GISJOIN*"
  join_vars <- intersect(names(data), names(sf_data))
  join_vars <- fostr_subset(join_vars, "GISJOIN.*")

  # Drop overlapping vars besides join var from shape file
  drop_vars <- dplyr::intersect(names(data), names(sf_data))
  drop_vars <- dplyr::setdiff(drop_vars, join_vars)
  sf_data <- dplyr::select(sf_data, -one_of(drop_vars))

  # Avoid a warning by adding attributes from the join_vars in data to
  # join_vars in sf_data
  purrr::walk(join_vars, function(vvv) {
    attributes(sf_data[[vvv]]) <<- attributes(data[[vvv]])
  })

  # Coerce to data.frame to avoid sf#414 (fixed in development version of sf)
  data <- dplyr::full_join(as.data.frame(sf_data), as.data.frame(data), by = join_vars)
  data <- sf::st_as_sf(tibble::as_tibble(data))

  # Check if any data rows are missing (merge failures where not in shape file)
  if (verbose) {
    missing_in_shape <- purrr::map_lgl(data$geometry, is.null)
    if (any(missing_in_shape)) {
      gis_join_failures <- data$GISJOIN[missing_in_shape]
      cat(paste(
        custom_format_text(
          "There are ", sum(missing_in_shape), " rows of data that ",
          "have data but no geography. This can happen because:"
        ),
        custom_format_text(
          "Shape files do not include some census geographies such ",
          "as 'Crews of Vessels' tracts that do not have a defined area",
          indent = 2, exdent = 2
        ),
        custom_format_text(
          "Shape files have been simplified which sometimes drops ",
          "entire geographies (especially small ones)."
        ),
        sep = "\n"
      ))
    }
  }
  data
}

#' @rdname read_nhgis
#' @export
read_nhgis_sp <- function(
  data_file,
  shape_file,
  data_layer = NULL,
  shape_layer = data_layer,
  shape_encoding = "latin1",
  verbose = TRUE,
  var_attrs = c("val_labels", "var_label", "var_desc")
) {
  data <- read_nhgis(data_file, !!enquo(data_layer), verbose)

  shape_layer <- enquo(shape_layer)
  if (quo_text(shape_layer) == "data_layer") shape_layer <- data_layer
  if (verbose) cat("Reading geography...\n")

  sp_data <- read_ipums_sp(
    shape_file, !!shape_layer, verbose = verbose, encoding = shape_encoding
  )

  # Only join on vars that are in both and are called "GISJOIN*"
  join_vars <- intersect(names(data), names(sp_data@data))
  join_vars <- fostr_subset(join_vars, "GISJOIN.*")

  # Drop overlapping vars besides join var from shape file
  drop_vars <- dplyr::intersect(names(data), names(sp_data@data))
  drop_vars <- dplyr::setdiff(drop_vars, join_vars)
  sp_data@data <- dplyr::select(sp_data@data, -one_of(drop_vars))

  out <- sp::merge(sp_data, data, by = join_vars, all.x = TRUE)

  # Check if any data rows are missing (merge failures where not in shape file)
  if (verbose) {
    missing_in_shape <- dplyr::anti_join(
      dplyr::select(data, one_of(join_vars)),
      dplyr::select(out@data, one_of(join_vars)),
      by = join_vars
    )
    if (nrow(missing_in_shape) > 0) {
      gis_join_failures <- purrr::pmap_chr(missing_in_shape, function(...) paste(..., sep = "-"))
      message(paste0(
        "There are ", nrow(missing_in_shape), " rows of data that ",
        "have data but no geography. This can happen because:\n  Shape files ",
        "do not include some census geographies such as 'Crews of Vessels' ",
        "tracts that do not have a defined area\n  Shape files have been simplified ",
        "which sometimes drops entire geographies (especially small ones)."
      ))
    }
  }
  out
}

# Internal ---------------------

read_nhgis_fwf <- function(data_file, data_layer = NULL, ...) {

  data_layer <- enquo(data_layer)

  is_zip <- file_is_zip(data_file)
  is_dir <- file_is_dir(data_file)

  if (is_zip) {

    # Cannot use fwf_empty() col_positions on an unz() connection
    # Must unzip file to allow for fwf_empty() specification
    fwf_dir <- tempfile()
    dir.create(fwf_dir)
    on.exit(unlink(fwf_dir, recursive = TRUE))

    utils::unzip(data_file, exdir = fwf_dir)

    filename <- find_files_in(
      list.files(fwf_dir, full.names = TRUE),
      "dat",
      data_layer
    )

    if (length(filename) == 0) {
      rlang::abort(
        c(
          paste0("`data_layer` did not match any files in the provided `data_file`."),
          "i" = "Use `ipums_list_files()` to see available data files for this extract"
        )
      )
    }

    file <- list.files(
      fwf_dir,
      pattern = filename,
      full.names = TRUE,
      recursive = TRUE
    )

  } else if (is_dir) {
    filename <- find_files_in(data_file, "dat", data_layer)
    file <- file.path(data_file, filename)
  } else {
    file <- data_file
  }

  data <- readr::read_fwf(file, ...)

  data

}

read_nhgis_csv <- function(data_file, data_layer = NULL, ...) {

  data_layer <- enquo(data_layer)

  is_zip <- file_is_zip(data_file)
  is_dir <- file_is_dir(data_file)

  if (is_zip || is_dir) {
    filename <- find_files_in(data_file, "csv", data_layer)

    if (length(filename) == 0) {
      rlang::abort(
        c(
          paste0("`data_layer` did not match any files in the provided `data_file`."),
          "i" = "Use `ipums_list_files()` to see available data files for this extract"
        )
      )
    }
  }

  if (is_zip) {
    file <- unz(data_file, filename)
  } else if (is_dir) {
    file <- file.path(data_file, filename)
  } else {
    file <- data_file
  }

  data <- readr::read_csv(file, ...)

  # TODO: testing that reformatting this stuff does handle
  # header row correctly

  # If extract is NHGIS's "enhanced" csvs with an extra header row,
  # then remove the first row.
  # (determine by checking if the first row is entirely character
  # values that can't be converted to numeric)
  first_row_char <- all(
    purrr::map_lgl(
      readr::type_convert(data[1, ], col_types = readr::cols()),
      rlang::is_character
    )
  )

  if (first_row_char) {
    data <- readr::type_convert(data[-1, ], col_types = readr::cols())
  }

  data

}

# Fills in a default condition if we can't find codebook for nhgis
NHGIS_EMPTY_DDI <- make_ddi_from_scratch(
  ipums_project = "NHGIS",
  file_type = "rectangular",
  conditions = paste0(
    "Use of NHGIS data is subject to conditions, including that ",
    "publications and research which employ NHGIS data should cite it ",
    "appropiately. Please see www.nhgis.org for more information."
  )
)
