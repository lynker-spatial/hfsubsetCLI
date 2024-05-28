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
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
)

const DEFAULT_ENDPOINT string = "https://www.lynker-spatial.com/hydrofabric/hfsubset/"

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
  hfsubset -o ./poudre.gpkg -t nldi "nwissite:USGS-08279500"
  
  # Specifying layers and hydrofabric version
  hfsubset -o ./divides_nexus.gpkg -r "2.2" -t hl_uri "Gages-06752260"
  
  # Finding data around a coordinate point
  hfsubset -o ./sacramento_flowpaths.gpkg -t xy -121.494400,38.581573

Environment Variables:
  ${HFSUBSET_ENDPOINT} - Endpoint to use for subsetting, defaults to 'https://www.lynker-spatial.com/hydrofabric/hfsubset/'.
						 Note: the endpoint must end with a trailing slash.

Details:
  * Finding POI identifiers can be done visually through https://www.lynker-spatial.com/hydrolocations.html

  * When using identifier type 'xy', the coordinates are in OGC:CRS84 order, which is the same reference
    system as EPSG:4326 (WGS84), but uses longitude-latitude axis order rather than latitude-longitude.

  * When using identifier type 'nldi', the identifiers follow the syntax

      <featureSource>:<featureID>

	For example, USGS-08279500 is accessed with featureSource 'nwissite', so this gives the form 'nwissite:USGS-08279500'

Options:
`

type SubsetRequest struct {
	Id         []string
	IdType     *string
	Layers     []string
	SubsetType *string
	Weights    []string
	Version    *string
	Output     *string
}

var quiet bool = false
var debug bool = false
var verify bool = true
var dryRun bool = false

func sendRequest(method string, url string) (*http.Response, error) {
	req, err := http.NewRequest(method, url, nil)
	if err != nil {
		return nil, err
	}

	req.Header.Set("User-Agent", "hfsubsetCLI/0.1.0")

	return http.DefaultClient.Do(req)
}

func createSubsetEndpointUrl(endpoint string, opts *SubsetRequest) (*url.URL, error) {
	uri, err := url.Parse(endpoint)
	if err != nil {
		return nil, err
	}

	// Path
	uri.Path += "subset"

	// Query parameters
	params := url.Values{}

	for _, id := range opts.Id {
		params.Add("identifier", id)
	}

	params.Add("identifier_type", *opts.IdType)

	if opts.Layers != nil && len(opts.Layers) > 0 {
		for _, layer := range opts.Layers {
			params.Add("layer", layer)
		}
	}

	if opts.SubsetType != nil {
		params.Add("subset_type", *opts.SubsetType)
	}

	if opts.Weights != nil {
		for _, weight := range opts.Weights {
			params.Add("weights", weight)
		}
	}

	if opts.Version != nil {
		params.Add("version", *opts.Version)
	}

	// Append query parameters to uri
	uri.RawQuery = params.Encode()

	return uri, nil
}

func outputFile(path string, r io.Reader) (int64, error) {
	f, err := os.Create(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	return f.ReadFrom(r)
}

func endpointVerify(endpoint string) (string, error) {
	resp, err := sendRequest("HEAD", endpoint)
	if err != nil {
		return "", err
	}

	if resp.StatusCode != 200 && resp.StatusCode != 404 {
		return "", errors.New(resp.Status)
	}

	defer resp.Body.Close()

	ver := resp.Header.Get("X-HFSUBSET-API-VERSION")
	if ver == "" {
		ver = "0.1.0-alpha" // initial version, pre 0.1.0
	}

	return ver, nil
}

func endpointGet(endpoint string, opts *SubsetRequest, logger *log.Logger) (int64, error) {
	uri, err := createSubsetEndpointUrl(endpoint, opts)
	if err != nil {
		return 0, err
	}

	if dryRun {
		logger.Printf("[dry-run] GET /subset?%s\n", uri.RawQuery)
		return 0, nil
	} else {
		logger.Printf("GET /subset?%s\n", uri.RawQuery)
	}

	// Perform request
	resp, err := sendRequest("GET", uri.String())
	if err != nil {
		return 0, err
	}

	if resp.StatusCode != 200 {
		return 0, fmt.Errorf("hfsubset service returned status %s", resp.Status)
	}

	defer resp.Body.Close()

	logger.Printf("writing response to %s\n", *opts.Output)
	return outputFile(*opts.Output, resp.Body)
}

func main() {
	flag.Usage = func() {
		fmt.Fprint(os.Stderr, USAGE)
		flag.PrintDefaults()
	}
	opts := SubsetRequest{}
	opts.IdType = flag.String("t", "hf", `One of: "hf", "comid", "hl", "poi", "nldi", or "xy"`)
	opts.SubsetType = flag.String("s", "reference", `Hydrofabric type, only "reference" is supported`)
	opts.Version = flag.String("v", "2.2", "Hydrofabric version (NOTE: omit the preceeding v)")
	opts.Output = flag.String("o", "hydrofabric.gpkg", "Output file name")
	flag.BoolVar(&quiet, "quiet", false, "Disable logging")
	flag.BoolVar(&debug, "debug", false, "Run in debug mode")
	flag.BoolVar(&verify, "verify", true, "Verify that endpoint is available")
	flag.BoolVar(&dryRun, "dryrun", false, "Perform a dry run, only outputting the request that will be sent")
	layers := flag.String("l", "divides,flowlines,network,nexus", "Comma-delimited list of layers to subset.")
	weights := flag.String("w", "", "Comma-delimited list of weights to generate over the subset.")
	flag.Parse()

	if len(flag.Args()) == 0 {
		flag.Usage()
		return
	}

	opts.Layers = append(opts.Layers, strings.Split(*layers, ",")...)
	opts.Weights = append(opts.Weights, strings.Split(*weights, ",")...)

	args := flag.Args()
	for _, arg := range args {
		if !strings.HasPrefix(arg, "-") {
			opts.Id = append(opts.Id, arg)
		}
	}

	var logPrefix string
	if noColor, ok := os.LookupEnv("NO_COLOR"); ok && noColor == "1" {
		logPrefix = "hfsubset ==> "
	} else {
		logPrefix = "\x1b[1;34mhfsubset\x1b[0m \x1b[2;37m==>\x1b[0m "
	}

	logger := log.New(os.Stdout, logPrefix, log.Ltime)
	if quiet {
		logger.SetOutput(io.Discard)
	}

	var endpoint string
	if v, ok := os.LookupEnv("HFSUBSET_ENDPOINT"); ok {
		endpoint = v
	} else {
		endpoint = DEFAULT_ENDPOINT
	}

	// ensure endpoint has a trailing slash
	if endpoint[len(endpoint)-1] != '/' {
		endpoint += "/"
	}

	// verify via root endpoint HEAD request
	if verify {
		version, err := endpointVerify(endpoint)
		if err != nil {
			logger.Fatalf("failed to verify hfsubset endpoint: %s\n", err.Error())
		}

		logger.Printf("verified hfsubset endpoint %s (version %s)", endpoint, version)
	}

	// perform subsetting and outputting
	_, err := endpointGet(endpoint, &opts, logger)
	if err != nil {
		logger.Fatalf("failed to complete hfsubset request: %s\n", err.Error())
	}
}
