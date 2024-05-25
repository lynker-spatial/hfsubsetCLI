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

logger::log_formatter(logger::formatter_glue_safe)

mount <- Sys.getenv("HFSUBSET_API_MOUNT", "UNSET")
if (mount == "UNSET") {
  mount <- NULL # use default
}

parse_id <- function(identifier) {
  strsplit(identifier, ",", fixed = TRUE)[[1]]
}

parse_nldi <- function(identifier) {
  as.list(setNames(
    strsplit(identifier, ":", fixed = TRUE)[[1]],
    c("featureSource", "featureID")
  ))
}

parse_xy <- function(identifier) {
  as.numeric(strsplit(identifier, ",", fixed = TRUE)[[1]])
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


#* Subset endpoint
#* @param identifier:[string]
#* @param identifier_type:string
#* @param subset_type:string
#* @param version:string
#* @serializer contentType list(type="application/geopackage+vnd.sqlite3")
#* @get /subset
#* @response 200 GeoPackage subset of the hydrofabric
function(
  identifier,
  identifier_type,
  subset_type = c("reference"),
  version = c("2.2")
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

  tmp <- tempfile(fileext = ".gpkg")
  on.exit({
    unlink(tmp)
  })

  call_args$type <- subset_type
  call_args$hf_version <- version
  call_args$outfile <- tmp

  if (!is.null(mount)) {
    call_args$source <- mount
  }

  tryCatch({
    call_result <- do.call(hfsubsetR::get_subset, call_args)
    file_size <- file.info(tmp)$size
    logger::log_success("retrieved subset of size {file_size}")
    readBin(tmp, "raw", n = file_size)
  }, error = \(cnd) {
    logger::log_error("failed to subset hydrofabric: {msg}", msg = cnd$message)
    rlang::abort("failed to subset hydrofabric", class = "error_500")
  })
}
