# This file is part of hfsubset.
#
# Copyright 2023 Mike Johnson, Justin Singh-Mohudpur
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

options(box.path = "/")
box::use(hydrofabric = hydrofabric/subset/subset_network)
cache_dir <- tempdir()

na_if_null <- function(x) if (is.null(x)) "NULL" else x

subset <- function(
    id           = NULL,
    comid        = NULL,
    hl_uri       = NULL,
    nldi_feature = NULL,
    xy           = NULL,
    layers       = c("divides",
                     "nexus",
                     "flowpaths",
                     "network",
                     "hydrolocations",
                     "reference_flowline",
                     "reference_catchment",
                     "refactored_flowpaths",
                     "refactored_divides"),
    version      = c("v20",
                     "00_reference",
                     "01_reference",
                     "02_refactored",
                     "03_uniform")
) {
    version <- match.arg(version)
    s3_uri  <- paste0("s3://lynker-spatial/", version, "/")

    missing_all <- is.null(id)     &&
                   is.null(comid)  &&
                   is.null(hl_uri) &&
                   is.null(nldi_feature)   &&
                   is.null(xy)

    if (missing_all) {
        return(list(
            "response" = "Error",
            "status"   = 400,
            "message"  = "No ID parameters were given."
        ))
    }

    logger::log_info(glue::glue(
        "[subset] Received request:",
        "{{",
        "  s3: {s3_uri}, ",
        "  id: {na_if_null(id)}, ",
        "  comid: {na_if_null(comid)}, ",
        "  hl_uri: {na_if_null(hl_uri)}, ",
        "  nldi_feature: {na_if_null(nldi_feature)}, ",
        "  xy: {na_if_null(xy)}, ",
        "  layers: {paste0(layers, collapse = ',')}, ",
        "  version: {version}",
        "}}",
        .sep = "\n"
    ))

    hf_tmp <- tempfile(fileext = ".gpkg")
    on.exit(unlink(hf_tmp))

    hydrofabric$subset_network(
        id           = id,
        comid        = comid,
        hl_uri       = hl_uri,
        nldi_feature = nldi_feature,
        xy           = xy,
        base_s3      = s3_uri,
        lyrs         = layers,
        outfile      = hf_tmp,
        cache_dir    = cache_dir,
        qml_dir      = "/hydrofabric/inst/qml"
    )

    base64enc::base64encode(readr::read_file_raw(hf_tmp))
}

lambdr::start_lambda(config = lambdr::lambda_config(
    environ = parent.frame()
))
