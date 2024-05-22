// This file is part of hfsubset.
//
// Copyright 2023- Mike Johnson, Justin Singh-Mohudpur
//
// hfsubset is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License,
// or (at your option) any later version.
//
// hfsubset is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty
// of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
// See the GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with hfsubset. If not, see <LICENSE.md> or
// <https://www.gnu.org/licenses/>.

package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
)

const DEFAULT_ENDPOINT string = "http://localhost:3101"

const USAGE string = `hfsubset - Hydrofabric Subsetter

Usage:
  hfsubset [OPTIONS] identifiers...
  hfsubset (-h | --help)

Examples:
  hfsubset -o ./divides_nexus.gpkg \
           -r "2.2"                 \
           -t hl_uri                   \
           "Gages-06752260"

  hfsubset -o ./poudre.gpkg -t hl_uri "Gages-06752260"

  # Using network-linked data index identifiers
  hfsubset -o ./poudre.gpkg -t nldi_feature "nwissite:USGS-08279500"
  
  # Specifying layers and hydrofabric version
  hfsubset -o ./divides_nexus.gpkg -r "2.2" -t hl_uri "Gages-06752260"
  
  # Finding data around a POI
  hfsubset -o ./sacramento_flowpaths.gpkg -t xy -121.494400,38.581573

Options:
`

type SubsetRequest struct {
	id          []string
	id_type     *string
	subset_type *string
	version     *string
	output      *string
}

func endpointGet(endpoint string, opts *SubsetRequest, logger *log.Logger) (int64, error) {
	uri, err := url.Parse(endpoint)
	if err != nil {
		return 0, err
	}

	// Path
	uri.Path += "subset"

	// Query parameters
	params := url.Values{}
	params.Add("identifier", strings.Join(opts.id, ","))
	params.Add("identifier_type", *opts.id_type)

	if opts.subset_type != nil {
		params.Add("subset_type", *opts.subset_type)
	}

	if opts.version != nil {
		params.Add("version", *opts.version)
	}

	// Append query parameters to uri
	uri.RawQuery = params.Encode()

	logger.Printf("sending request %s\n", uri.String())

	// Perform request
	resp, err := http.Get(uri.String())
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()

	f, err := os.Create(*opts.output)
	if err != nil {
		return 0, err
	}
	defer f.Close()

	logger.Printf("writing response to %s\n", *opts.output)

	return f.ReadFrom(resp.Body)
}

func main() {
	flag.Usage = func() {
		fmt.Fprint(os.Stderr, USAGE)
		flag.PrintDefaults()
	}

	opts := new(SubsetRequest)
	opts.id_type = flag.String("t", "hf", `One of: "hf", "comid", "hl", "poi", "nldi", or "xy"`)
	opts.subset_type = flag.String("s", "reference", `Hydrofabric type, only "reference" is supported`)
	opts.version = flag.String("v", "2.2", "Hydrofabric version (NOTE: omit the preceeding `v`)")
	opts.output = flag.String("o", "hydrofabric.gpkg", "Output file name")
	quiet := flag.Bool("quiet", false, "Disable logging")

	flag.Parse()

	if len(flag.Args()) == 0 {
		flag.Usage()
		return
	}

	opts.id = flag.Args()
	logger := log.New(os.Stdout, "hfsubset ==> ", log.Ltime)
	if *quiet {
		logger.SetOutput(io.Discard)
	}

	var endpoint string
	if v, ok := os.LookupEnv("HFSUBSET_ENDPOINT"); ok {
		endpoint = v
	} else {
		endpoint = DEFAULT_ENDPOINT
	}

	_, err := endpointGet(endpoint, opts, logger)
	if err != nil {
		logger.Fatalf("failed to complete hfsubset request: %s\n", err.Error())
	}
}
