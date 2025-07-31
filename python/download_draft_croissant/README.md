# Download Croissant from draft dataset

[Croissant](https://github.com/mlcommons/croissant) is an ([optional](https://github.com/IQSS/dataverse/issues/11254)) export format for Dataverse.

This script was written because while the ability to download export formats from draft datasets was implemented for Dataverse 6.7 (see <https://github.com/IQSS/dataverse/pull/11398>), the feature is API-only. This script tries to make it easier to use the appropriate API.

Before using this script it would be best to check with the admins of your Dataverse installation if they have upgraded to Dataverse 6.7 (the equivalent of <https://demo.dataverse.org/api/info/version> can give you a clue) and if they have upgraded to version 0.1.4 or higher of the [Croissant exporter](https://github.com/gdcc/exporter-croissant). As of Dataverse 6.5 you can check if it is enabled by visiting the equivalent of <https://demo.dataverse.org/api/info/exportFormats> on your Dataverse installation (but you can't tell which version is installed).

Here is the help as of this writing:

```
% python download_draft_croissant.py -h
usage: download_draft_croissant.py [-h] -b BASE_URL [-a API_TOKEN] -p PID [-u] [-v]

Download a Croissant file from a draft dataset in a Dataverse installation.

options:
  -h, --help            show this help message and exit
  -b, --base_url BASE_URL
                        The base URL of the Dataverse installation such as https://beta.dataverse.org
  -a, --api_token API_TOKEN
                        The API token to use for authentication. This is required for draft datasets. If
                        not provided, it will be read from the API_TOKEN environment variable.
  -p, --pid PID         The persistent identifier (PID) of the draft dataset such as
                        doi:10.5072/FK2/XXXXXX
  -u, --ugly            Don't pretty-print the JSON output.
  -v, --verbose         Show more output.
```
