package sshbridge

import "testing"

func TestParseDestination(t *testing.T) {
	cases := []struct {
		in   string
		want Destination
	}{
		{"host", Destination{Host: "host"}},
		{"alde@host", Destination{User: "alde", Host: "host"}},
		{"host:2222", Destination{Host: "host", Port: 2222}},
		{"alde@host:2222", Destination{User: "alde", Host: "host", Port: 2222}},
		{"me@corp@host", Destination{User: "me@corp", Host: "host"}},
		{"::1", Destination{Host: "::1"}},
		{"[::1]", Destination{Host: "::1"}},
		{"[::1]:2222", Destination{Host: "::1", Port: 2222}},
		{"alde@[fe80::1]:22", Destination{User: "alde", Host: "fe80::1", Port: 22}},
		{"ssh://host", Destination{Host: "host"}},
		{"ssh://alde@host:2222", Destination{User: "alde", Host: "host", Port: 2222}},
		{"ssh://alde@[::1]:2222/", Destination{User: "alde", Host: "::1", Port: 2222}},
	}
	for _, tc := range cases {
		got, err := ParseDestination(tc.in)
		if err != nil {
			t.Errorf("%q: %v", tc.in, err)
			continue
		}
		if got != tc.want {
			t.Errorf("%q = %+v, want %+v", tc.in, got, tc.want)
		}
	}

	for _, bad := range []string{"", "alde@", "host:", "host:0", "host:70000", "host:ssh", "ssh://", "ssh://host/path"} {
		if d, err := ParseDestination(bad); err == nil {
			t.Errorf("%q = %+v, want error", bad, d)
		}
	}
}
