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

plumber::pr("api.R") |>
  plumber::pr_run(host = host, port = port)
