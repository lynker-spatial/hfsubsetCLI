# hfsubset - CLI-based Hydrofabric Subsetter

For those interested in using the NOAA NextGen fabric as is, we have
provided a Go-based CLI
[here](https://github.com/lynker-spatial/hfsubsetCLI/releases)

## Usage

This utility has the following syntax:

``` bash
hfsubset - Hydrofabric Subsetter

Usage:
  hfsubset [OPTIONS] identifiers...
  hfsubset (-h | --help)

Examples:
  hfsubset -o ./divides_nexus.gpkg \
           -r "2.2"                \
           -t hl                   \
           "Gages-06752260"

  hfsubset -o ./poudre.gpkg -t hl "Gages-06752260"

  # Using network-linked data index identifiers
  hfsubset -o ./poudre.gpkg -t nldi "nwissite:USGS-08279500"
  
  # Specifying layers and hydrofabric version
  hfsubset -o ./divides_nexus.gpkg -r "2.2" -t hl "Gages-06752260"
  
  # Finding data around a coordinate point
  hfsubset -o ./sacramento_flowpaths.gpkg -t xy -121.494400,38.581573

Details:
  * Finding POI identifiers can be done visually through https://www.lynker-spatial.com/hydrolocations.html

  * When using identifier type 'nldi', the identifiers follow the syntax

      <featureSource>:<featureID>

        For example, USGS-08279500 is accessed with featureSource 'nwissite', so this gives the form 'nwissite:USGS-08279500'

Options:
  -debug
        Run in debug mode
  -o string
        Output file name (default "hydrofabric.gpkg")
  -quiet
        Disable logging
  -s string
        Hydrofabric type, only "reference" is supported (default "reference")
  -t string
        One of: "hf", "comid", "hl", "poi", "nldi", or "xy" (default "hf")
  -v v
        Hydrofabric version (NOTE: omit the preceeding v) (default "2.2")
```

## License

`hfsubset` is distributed under [GNU General Public License v3.0 or later](LICENSE.md)
