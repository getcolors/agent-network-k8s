"""Launcher contract and name derivations, the port of
io.github.getcolors.agent-network-k8s.utils."""

from __future__ import annotations

import re

# Bump on any change a launcher pinned to an older commit could not survive.
CONTRACT = 1


def registrable_domain(host) -> str:
    """The registrable (zone) domain of a hostname: its last two labels. Good
    enough for the zones this package serves; a public-suffix list would be a
    dependency for a case no deployment has."""
    labels = str(host).split(".")
    return ".".join(labels[-2:])


def registry_name(profile) -> str:
    """What this deployment calls its container registry. Vultr registry names
    accept lowercase alphanumerics only, so the profile-derived name (Compute
    Name Standard) is the profile with every other character removed."""
    return re.sub(r"[^a-z0-9]", "", str(profile).lower())
