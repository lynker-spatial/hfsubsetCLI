// This file is part of hfsubset.
//
// Copyright 2023 Mike Johnson, Justin Singh-Mohudpur
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
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
)

const usage string = `hfsubset - Hydrofabric Subsetter

Usage:
  hfsubset [OPTIONS] identifiers...
  hfsubset (-h | --help)

Examples:
  hfsubset -l divides,nexus        \
           -o ./divides_nexus.gpkg \
           -r "v20"                 \
           -t hl_uri                   \
           "Gages-06752260"

  hfsubset -o ./poudre.gpkg -t hl_uri "Gages-06752260"

  # Using network-linked data index identifiers
  hfsubset -o ./poudre.gpkg -t nldi_feature "nwis:USGS-08279500"
  
  # Specifying layers and hydrofabric version
  hfsubset -l divides,nexus -o ./divides_nexus.gpkg -r "pre-release" -t hl_uri "Gages-06752260"
  
  # Finding data around a POI
  hfsubset -l flowpaths,reference_flowpaths -o ./sacramento_flowpaths.gpkg -t xy -121.494400,38.581573

Options:
`

type SubsetRequest struct {
	id      []string
	id_type *string
	layers  *string
	version *string
	output  *string
}

type SubsetResponse struct {
	data []byte
}

// Parse comma-delimited layers string
func (opts *SubsetRequest) Layers() []string {
	split := strings.Split(*opts.layers, ",")
	for i, v := range split {
		split[i] = strings.TrimSpace(v)
	}
	return split
}

// Parse IDs format, i.e. trim spaces
func (opts *SubsetRequest) IDs(key string) []string {
	for i, v := range opts.id {
		opts.id[i] = strings.TrimSpace(v)
	}

	if key == "nldi_feature" {
		var feat struct {
			FeatureSource string `json:"featureSource"`
			FeatureId     string `json:"featureId"`
		}

		feat.FeatureSource = ""
		feat.FeatureId = ""
		for i, v := range opts.id {
			f := strings.Split(v, ":")

			feat.FeatureSource = f[0]
			feat.FeatureId = f[1]
			fstr, _ := json.Marshal(feat)
			opts.id[i] = string(fstr)
			feat.FeatureSource = ""
			feat.FeatureId = ""
		}
	}

	if key == "xy" {
		var xy struct {
			X float64
			Y float64
		}

		xy.X = -1
		xy.Y = -1
		for i, v := range opts.id {
			f := strings.Split(v, ",")

			xy.X, _ = strconv.ParseFloat(f[0], 64)
			xy.Y, _ = strconv.ParseFloat(f[1], 64)

			fstr, _ := json.Marshal(xy)
			opts.id[i] = string(fstr)
			xy.X = -1
			xy.Y = -1
		}
	}

	return opts.id
}

func (opts *SubsetRequest) MarshalJSON() ([]byte, error) {
	var key string
	jsonmap := make(map[string]any)

	switch *opts.id_type {
	case "id":
		key = "id"
	case "hl_uri":
		key = "hl_uri"
	case "comid":
		key = "comid"
	case "nldi_feature":
		key = "nldi_feature"
	case "xy":
		key = "xy"
	default:
		panic("type " + *opts.id_type + " not supported; only one of: id, hl_uri, comid, nldi_feature, xy")
	}

	jsonmap["layers"] = opts.Layers()
	jsonmap[key] = opts.IDs(key)
	jsonmap["version"] = *opts.version
	return json.Marshal(jsonmap)
}

func makeRequest(lambda_endpoint string, opts *SubsetRequest, logger *log.Logger) *SubsetResponse {
	var uri string = lambda_endpoint + "/2015-03-31/functions/function/invocations"
	payload, err := opts.MarshalJSON()
	if err != nil {
		panic(err)
	}

	reader := bytes.NewReader(payload)

	logger.Println("[1/4] waiting for response")
	req, err := http.Post(uri, "application/json", reader)
	if err != nil {
		panic(err)
	}
	defer req.Body.Close()

	logger.Println("[2/4] reading hydrofabric subset")
	resp := new(SubsetResponse)
	b := new(bytes.Buffer)
	buffer := bufio.NewWriter(b)
	_, err = io.Copy(buffer, req.Body)
	if err != nil {
		panic(err)
	}

	r := b.Bytes()

	// Trim quotes if returned
	if r[0] == '"' && r[len(r)-1] == '"' {
		r = r[1 : len(r)-1]
	}

	logger.Println("[3/4] parsing base64 response")
	rr := bytes.NewReader(r)
	gpkg := base64.NewDecoder(base64.StdEncoding, rr)
	resp.data, err = io.ReadAll(gpkg)
	if err != nil {
		panic(err)
	}

	return resp
}

func writeToFile(request *SubsetRequest, response *SubsetResponse, logger *log.Logger) int {
	f, err := os.Create(*request.output)
	if err != nil {
		panic(err)
	}

	logger.Printf("[4/4] writing to %s", *request.output)
	w := bufio.NewWriter(f)
	n, err := w.Write(response.data)
	if err != nil {
		panic(err)
	}

	return n
}

func main() {
	flag.Usage = func() {
		fmt.Fprint(os.Stderr, usage)
		flag.PrintDefaults()
	}

	layers_help := `Comma-delimited list of layers to subset.
Either "all" or "core", or one or more of:
    "divides", "nexus", "flowpaths", "flowpath_attributes",
    "network", "hydrolocations", "lakes", "reference_flowline",
    "reference_catchment", "reference_flowpaths", "reference_divides"`

	opts := new(SubsetRequest)
	opts.id_type = flag.String("t", "id", `One of: "id", "hl_uri", "comid", "xy", or "nldi_feature"`)
	opts.layers = flag.String("l", "core", layers_help)
	opts.version = flag.String("r", "pre-release", "Hydrofabric version")
	opts.output = flag.String("o", "hydrofabric.gpkg", "Output file name")
	quiet := flag.Bool("quiet", false, "Disable progress bar")
	flag.Parse()

	opts.id = flag.Args()
	if len(opts.id) == 0 {
		flag.Usage()
		return
	}

	if *opts.layers == "all" {
		*opts.layers = "divides,nexus,flowpaths,network,hydrolocations,lakes,reference_flowline,reference_catchment,reference_flowpaths,reference_divides"
	}

	if *opts.layers == "core" {
		*opts.layers = "divides,nexus,flowpaths,network,hydrolocations"
	}

	logger := log.New(os.Stdout, "hfsubset ==> ", log.Ltime)
	if *quiet {
		logger.SetOutput(io.Discard)
	}
	logger.Println("[0/4] sending http request")

	var endpoint string
	if v, ok := os.LookupEnv("HFSUBSET_ENDPOINT"); ok {
		endpoint = v
	} else {
		// TODO: Change to AWS endpoint
		endpoint = "https://hfsubset-e9kvx.ondigitalocean.app"
	}

	resp := makeRequest(endpoint, opts, logger)
	response_size := len(resp.data)
	bytes_written := writeToFile(opts, resp, logger)

	if bytes_written != response_size {
		panic(fmt.Sprintf("wrote %d bytes out of %d bytes to %s", bytes_written, response_size, *opts.output))
	}
}
