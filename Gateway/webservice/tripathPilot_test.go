package webservice

import (
	"strings"
	"testing"
)

func TestTripathDestinationIsSingleAuthorizedPilot(t *testing.T) {
	base := tripathPilotConfig{Enabled: true, Device: tripathPilotDevice, URL: "wss://70.39.202.192:19444/screen/ws", Token: strings.Repeat("a", 64), CertSHA256: strings.Repeat("b", 64)}
	if err := validateTripathPilotConfig(base); err != nil {
		t.Fatal(err)
	}
	for _, alter := range []func(*tripathPilotConfig){func(c *tripathPilotConfig) { c.Device = "ZY22F68DH8" }, func(c *tripathPilotConfig) { c.URL = "ws://70.39.202.192:19444/screen/ws" }, func(c *tripathPilotConfig) { c.URL = "wss://other.example/screen/ws" }, func(c *tripathPilotConfig) { c.URL += "?token=x" }, func(c *tripathPilotConfig) { c.CertSHA256 = "bad" }, func(c *tripathPilotConfig) { c.Token = "short" }} {
		c := base
		alter(&c)
		if validateTripathPilotConfig(c) == nil {
			t.Fatal("accepted unsafe pilot config")
		}
	}
}
