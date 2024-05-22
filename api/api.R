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

#* Subset endpoint
#* @param identifier
#* @param identifier_type
#* @param subset_type
#* @param version
#* @serializer contentType list(type="application/geopackage+vnd.sqlite3")
#* @get /subset
function(
  identifier,
  identifier_type = c("hf", "comid", "hl", "poi", "nldi", "xy"),
  subset_type = c("reference"),
  version = c("2.2")
) {
  identifier_type <- match.arg(identifier_type)
  subset_type <- match.arg(subset_type)
  version <- match.arg(version)

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

  call_result <- do.call(hfsubsetR::get_subset, call_args)
  readBin(tmp, "raw", n = file.info(tmp)$size)
}
