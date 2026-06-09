# Root Cause Analysis: SSSD vs NSLCD

## Issue Description
The `sssd` daemon fails to start or work as expected, while `nslcd` works seamlessly in the identical environment. Both are used to connect the system's Name Service Switch (NSS) and PAM modules to a central LDAP directory.

## Root Cause
The root cause lies in the structure and strictness of the respective configuration files.

1.  **Missing `[sssd]` Block:** `sssd` (System Security Services Daemon) uses a multi-section `.ini` style configuration file (`sssd.conf`). By default and design, SSSD **requires** a primary `[sssd]` section where it defines fundamental operational parameters:
    *   `config_file_version = 2`
    *   `services` (e.g., `nss`, `pam`)
    *   `domains` (the active domains it should manage)

    The provided `sssd.conf` entirely lacked this `[sssd]` block, as well as the specific `[nss]` and `[pam]` blocks. Because SSSD didn't know which version of config to parse, which services to start, or which domains were active, it failed to initialize.

2.  **Monolithic vs Modular Configs:** In contrast, `nslcd` (Name Service LDAP Connection Daemon) uses a simpler, monolithic `nslcd.conf`. It doesn't have concepts like "domains" or distinct "services" in its config structure. It simply defines the LDAP URI, bind credentials, and search mappings globally. Since the provided `nslcd.conf` had these raw values correctly defined, it was able to successfully bind to LDAP and fetch user/group data.

## Solution
To resolve the issue and allow SSSD to function (particularly within the Slinky Kubernetes pods where SSSD is natively supported via `values.yaml`), the `sssd.conf` must be updated to include the necessary `[sssd]`, `[nss]`, and `[pam]` sections, explicitly activating the `sandbox.local` domain.