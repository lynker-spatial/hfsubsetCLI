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
	"net/http"
	"os"
	"strings"

	"github.com/schollz/progressbar/v3"
)

const usage string = `hfsubset - Hydrofabric Subsetter

Usage:
  hfsubset [OPTIONS] identifiers...
  hfsubset (-h | --help)

Examples:
  hfsubset -l divides,nexus        \
           -o ./divides_nexus.gpkg \
           -r "v2.0"        \
           -t hl_uri                   \
           "Gages-06752260"

  hfsubset -o ./poudre.gpkg -t hl_uri "Gages-06752260"

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

func (opts *SubsetRequest) Layers() []string {
	split := strings.Split(*opts.layers, ",")
	for i, v := range split {
		split[i] = strings.TrimSpace(v)
	}
	return split
}

func (opts *SubsetRequest) IDs() []string {
	for i, v := range opts.id {
		opts.id[i] = strings.TrimSpace(v)
	}
	return opts.id
}

func (opts *SubsetRequest) MarshalJSON() ([]byte, error) {
	var key string
	jsonmap := make(map[string]any)

	switch *opts.id_type {
	case "id":
		key = "id"
		break
	case "hl_uri":
		key = "hl_uri"
		break
	case "comid":
		key = "comid"
		break
	case "nldi_feature":
		// key = "nldi"
		// break
		fallthrough
	case "xy":
		// key = "loc"
		// break
		panic("-nldi_feature and -xy support are not implemented currently")
	default:
		panic("type " + *opts.id_type + " not supported; only one of: id, hl_uri, comid, nldi_feature, xy")
	}

	jsonmap["layers"] = opts.Layers()
	jsonmap[key] = opts.IDs()
	jsonmap["version"] = "v20" // v20 is v2.0
	return json.Marshal(jsonmap)
}

func makeRequest(lambda_endpoint string, opts *SubsetRequest, bar *progressbar.ProgressBar) *SubsetResponse {
	var uri string = lambda_endpoint + "/2015-03-31/functions/function/invocations"
	payload, err := opts.MarshalJSON()
	if err != nil {
		panic(err)
	}

	reader := bytes.NewReader(payload)

	bar.Describe("[1/4] waiting for response")
	req, err := http.Post(uri, "application/json", reader)
	if err != nil {
		panic(err)
	}
	defer req.Body.Close()

	bar.Describe("[2/4] reading hydrofabric subset")
	resp := new(SubsetResponse)
	b := new(bytes.Buffer)
	buffer := bufio.NewWriter(b)
	_, err = io.Copy(buffer, req.Body)
	if err != nil {
		panic(err)
	}

	r := b.Bytes()
	if r[0] == '"' && r[len(r)-1] == '"' {
		r = r[1 : len(r)-1]
	}

	bar.Describe("[3/4] decoding gzip")
	rr := bytes.NewReader(r)
	gpkg := base64.NewDecoder(base64.StdEncoding, rr)
	// gpkg, _ := gzip.NewReader(rr)
	// defer gpkg.Close()
	resp.data, err = io.ReadAll(gpkg)
	if err != nil {
		panic(err)
	}

	return resp
}

func writeToFile(request *SubsetRequest, response *SubsetResponse, bar *progressbar.ProgressBar) int {
	f, err := os.Create(*request.output)
	if err != nil {
		panic(err)
	}

	bar.Describe(fmt.Sprintf("[4/4] writing to %s", *request.output))
	w := bufio.NewWriter(f)
	mw := io.MultiWriter(w, bar)
	n, err := mw.Write(response.data)
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

	bar := progressbar.NewOptions(3,
		progressbar.OptionSetWidth(15),
		progressbar.OptionSetDescription("[0/4] sending http request"),
		progressbar.OptionShowBytes(false),
		progressbar.OptionSetVisibility(!*quiet),
	)

	var endpoint string
	if v, ok := os.LookupEnv("HFSUBSET_ENDPOINT"); ok {
		endpoint = v
	} else {
		// TODO: Change to AWS endpoint
		endpoint = "https://hfsubset-e9kvx.ondigitalocean.app"
	}

	resp := makeRequest(endpoint, opts, bar)
	response_size := len(resp.data)
	bytes_written := writeToFile(opts, resp, bar)
	bar.Finish()
	println() // so progress bar doesn't show up

	if bytes_written != response_size {
		panic(fmt.Sprintf("wrote %d bytes out of %d bytes to %s", bytes_written, response_size, *opts.output))
	}
}
