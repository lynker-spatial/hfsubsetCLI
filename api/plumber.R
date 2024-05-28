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

host <- Sys.getenv("HFSUBSET_API_HOST", "UNSET")
if (host == "UNSET") {
  host <- "0.0.0.0"
}

port <- Sys.getenv("HFSUBSET_API_PORT", "UNSET")
if (port == "UNSET") {
  port <- 8080L
}
port <- as.integer(port)

error_handler <- function(req, res, err) {
  res$serializer <- plumber::serializer_unboxed_json()

  rlang::try_fetch({
    rlang::cnd_signal(err)
  }, error_400 = \(cnd) {
    res$status <- 400
    list(error = "Service failed to process user request",
         message = rlang::cnd_message(cnd))
  }, error_500 = \(cnd) {
    res$status <- 500
    list(error = "Service failed to process user request",
         message = rlang::cnd_message(cnd))
  }, error = \(cnd) {
    res$status <- 500
    msg <- rlang::cnd_message(cnd)
    logger::log_error("Unhandled internal error: {msg}")
    list(error = "Internal Server Error")
  })
}

logger::log_info("Listening for requests on ", paste0(host, ":", port))

tryCatch({
  plumber::pr("api.R") |>
    plumber::pr_set_error(error_handler) |>
    plumber::pr_run(host = host, port = port, quiet = TRUE)
}, error = function(cnd) {
  logger::log_error("api fatal internal failure: {msg}", msg = cnd$message)
  rlang::abort("API Fatal Internal Failure")
})
