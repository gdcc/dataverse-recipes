# Create Croissant Client-Side

If your installation of Dataverse doesn't have the [Croissant exporter](https://github.com/gdcc/exporter-croissant) enabled, you can create a Croissant file client-side using pyDataverse.

Please note that pyDataverse creates a Croissant file that is somewhat [different](https://github.com/gdcc/exporter-croissant#differences-from-pydataverse) than the one generated server-side by Dataverse. Hopefully it will be close enough for your needs.

```
python3 -m venv venv
source venv/bin/activate
pip install --upgrade --no-cache-dir  git+https://github.com/Dans-labs/pyDataverse@development#egg=pyDataverse --break-system-packages
python export-croissant.py
```
