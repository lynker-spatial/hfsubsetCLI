package main_test

import (
	"fmt"
	"testing"

	m "github.com/lynker-spatial/hfsubsetCLI"
)

const endpoint string = "http://1.2.3.4:5678"

func helperMakeDefaultRequest(id []string, id_type string) m.SubsetRequest {
	req := m.SubsetRequest{
		Id:         make([]string, len(id)),
		IdType:     new(string),
		SubsetType: nil,
		Version:    nil,
		Output:     nil,
	}

	copy(req.Id, id)
	*req.IdType = id_type
	return req
}

func helperTestUrl(t *testing.T, req *m.SubsetRequest, res *string) {
	uri, err := m.CreateSubsetEndpointUrl(endpoint, req)
	if err != nil {
		t.Errorf("failed to create subset url: %s", err.Error())
	}

	if uri.String() != *res {
		t.Errorf("failed to create subset url: \"%s\" != \"%s\"", uri.String(), *res)
	}
}

func helperMakeEndpoint(queryParams string) string {
	return fmt.Sprintf("%s/subset%s", endpoint, queryParams)
}

func TestSubsetEndpointCreation(t *testing.T) {
	cases := []struct {
		Test     m.SubsetRequest
		Expected string
	}{
		{helperMakeDefaultRequest(
			[]string{"101"}, "comid"),
			helperMakeEndpoint("?identifier=101&identifier_type=comid")},
		{helperMakeDefaultRequest(
			[]string{"nwissite:USGS-12345678"}, "nldi"),
			helperMakeEndpoint("?identifier=nwissite%3AUSGS-12345678&identifier_type=nldi")},
		{helperMakeDefaultRequest(
			[]string{"123.456,-98.76543"}, "xy"),
			helperMakeEndpoint("?identifier=123.456%2C-98.76543&identifier_type=xy")},
	}

	for _, val := range cases {
		helperTestUrl(t, &val.Test, &val.Expected)
	}
}
