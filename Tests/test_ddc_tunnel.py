"""Keep the research-only DDC tunnel protocol testable outside the shipped driver."""

from Support import oizyscore as core


def test_ddc_tunnel_protocol_selftest():
    assert core.lib.oizys_ddc_tunnel_selftest() == 0
