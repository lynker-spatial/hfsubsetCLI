# This file is part of hfsubset.
#
# Copyright 2023- Mike Johnson, Justin Singh-Mohudpur
#
# hfsubset is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published
# by the Free Software Foundation, either version 3 of the License,
# or (at your option) any later version.
#
# hfsubset is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty
# of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with hfsubset. If not, see <LICENSE.md> or
# <https://www.gnu.org/licenses/>.

#* @apiTitle Hydrofabric Subsetter
#* @apiDescription This is a REST API for subsetting cloud-native hydrofabrics.
#* @apiContact list(name = "hfsubsetCLI API Support", email = "jjohnson@lynker.com")
#* @apiLicense list(name = "GNU General Public License (GPL-3.0)", url = "https://www.gnu.org/licenses/")
#* @apiVersion 1.1.0

future::plan(future::multisession)

logger::log_formatter(logger::formatter_glue_safe)

cache_dir <- Sys.getenv("HFSUBSET_API_CACHE_DIR", "UNSET")
if (cache_dir == "UNSET") {
  cache_dir <- NULL
}

cache_destroy <- Sys.getenv("HFSUBSET_API_CACHE_KEEP", "UNSET")
if (cache_destroy == "UNSET") {
  cache_destroy <- TRUE
} else if (is.na(as.logical(cache_destroy))) {
  logger::log_warn(
    "parsing $HFSUBSET_API_CACHE_KEEP returned NA, defaulting to TRUE"
  )
  cache_destroy <- TRUE
} else {
  cache_destroy <- FALSE
}

.has_qs <- requireNamespace("qs", quietly = TRUE)
if (!.has_qs) {
  logger::log_warn("qs is not available, falling back to RDS for cache")
}

subset_cache <- cachem::cache_disk(
  dir                 = cache_dir,
  max_size            = 5 * (1024 * 1024^2),
  max_age             = 604800, # 7 days in seconds
  evict               = "lru",
  destroy_on_finalize = TRUE,
  read_fn             = if (.has_qs) qs::qread else readRDS,
  write_fn            = if (.has_qs) qs::qsave else saveRDS
)


#' @keywords internal
parse_id <- function(identifier) {
  strsplit(identifier, ",", fixed = TRUE)[[1]]
}

#' @keywords internal
parse_nldi <- function(identifier) {
  as.list(setNames(
    strsplit(identifier, ":", fixed = TRUE)[[1]],
    c("featureSource", "featureID")
  ))
}

#' @keywords internal
parse_xy <- function(identifier) {
  as.numeric(strsplit(identifier, ",", fixed = TRUE)[[1]])
}

#' @keywords internal
hash_list <- function(l) {
  l[order(names(l))] |>
    deparse() |>
    strsplit("", fixed = TRUE, useBytes = TRUE) |>
    unlist(recursive = FALSE, use.names = FALSE) |>
    trimws() |>
    (\(y) y[y != ""])() |>
    paste(sep = "", collapse = "") |>
    rlang::hash()
}

#' Returns the subset based on `call_args`
#' @return in the environment `result`:
#'   - $size: byte length
#'   - $data: raw vector
#'   - $cache: character(1) of "hit" or "miss"
get_subset <- function(call_args, result, weight_args = list()) {
  key <- hash_list(call_args)

  hfdata <- NULL # list
  if (subset_cache$exists(key)) {
    result$cache <- "hit"
    hfdata <- subset_cache$get(key)
  } else {
    result$cache <- "miss"
    hfdata <- do.call(hfsubsetR::get_subset, call_args)
    subset_cache$set(key, hfdata)
  }

  if (length(weight_args) > 0 && "divides" %in% names(hfdata)) {
    for (weight in weight_args) {
      hfdata[[paste0("weight_grid_", weight)]] <-
        paste0(
          "s3://lynker-spatial/gridded-resources/",
          weight,
          ".forcing.tif"
        ) |>
        terra::rast() |>
        zonal::weight_grid(
          geom = hfdata$divides,
          ID = "divide_id",
          progress = FALSE
        ) |>
        dplyr::mutate(grid_id = paste0(weight, ".forcing"))
    }
  }

  outfile <- tempfile(fileext = ".gpkg")
  for (layer in names(hfdata)) {
    sf::write_sf(hfdata[[layer]], outfile, layer)
  }

  result$size <- file.size(outfile)
  result$data <- readBin(outfile, "raw", n = result$size)
  unlink(outfile)

  return(invisible(NULL))
}

# =============================================================================
# =============================================================================

#* @filter logger
function(req) {
  query <- jsonlite::toJSON(req$argsQuery, auto_unbox = TRUE)
  logger::log_info(
    "{REQUEST_METHOD} {PATH_INFO} - {HTTP_USER_AGENT}@{REMOTE_ADDR} - {query}",
    query = query,
    .topenv = req
  )
  plumber::forward()
}

#* Health Check
#* @head /health
function(req, res) {
  res$setHeader("X-HFSUBSET-API-VERSION", "1.1.1")
  res
}


#* Subset endpoint
#* @param identifier:[string] Unique identifiers associated with `identifer_type`
#* @param identifier_type:string Type of identifier passed (one of: `hf`, `comid`, `hl`, `poi`, `nldi`, `xy`]
#* @param layer:[string] Layers to return with a given subset, defaults to: [`divides`, `flowlines`, `network`, `nexus`]
#* @param subset_type:string Type of hydrofabric to subset (related to `version`)
#* @param weights:[string] Forcing weights to generate (any of: `medium_range`)
#* @param version:string Hydrofabric version to subset
#* @get /subset
#* @response 200 GeoPackage subset of the hydrofabric
#* @response 400 Invalid arguments error
#* @response 500 Internal runtime error
function(
  req,
  res,
  identifier,
  identifier_type,
  layer = c("divides", "flowlines", "network", "nexus"),
  weights = list(),
  domain = c("conus"),
  subset_type = c("reference"),
  version = c("2.2"),
  source = c('s3://lynker-spatial/hydrofabric')
) {
  .id_types <- c("hf", "comid", "hl", "poi", "nldi", "xy")
  if (!identifier_type %in% .id_types) {
    .types <- paste0(.id_types, collapse = ", ")
    errmsg <- glue::glue("identifier type '{identifier_type}' not one of: {(.types)}")
    logger::log_error(errmsg)
    rlang::abort(errmsg, class = "error_400")
  }

  call_args <- switch(identifier_type,
    hf = list(id = parse_id(identifier)),
    comid = list(comid = as.numeric(parse_id(identifier))),
    hl = list(hl_uri = parse_id(identifier)),
    poi = list(poi_id = as.numeric(parse_id(identifier))),
    nldi = list(nldi_feature = parse_nldi(identifier)),
    xy = list(xy = parse_xy(identifier))
  )

  #call_args$type <- subset_type
  #call_args$hf_version <- version
  call_args$lyrs <- layer
  call_args$gpkg <- glue('{source}/v{version}/{domain}/{domain}_{subset_type}.gpkg')

  promises::future_promise({
    tryCatch({
      result <- new.env()
      get_subset(call_args, result, weight_args = weights)
      logger::log_success(
        "retrieved subset of size {size}, cache: {cache}",
        .topenv = result
      )

      res$setHeader("Content-Length", result$size)
      res$setHeader("Content-Type", "application/geopackage+vnd.sqlite3")
      res$setHeader("Content-Disposition", "attachment; filename=\"subset.gpkg\"")
      res$setHeader("X-HFSUBSET-API-CACHE", result$cache)
      res$body <- result$data
      res
    }, error = \(cnd) {
      logger::log_error("failed to subset hydrofabric: {msg}", msg = cnd$message)
      rlang::abort("failed to subset hydrofabric", class = "error_500")
    })
  })
}
