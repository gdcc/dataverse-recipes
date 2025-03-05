from pyDataverse.Croissant import Croissant
import json

host = "https://dataverse.nl"
PID = "doi:10.34894/KMRAYH"
croissant = Croissant(host, PID)
print(json.dumps(croissant.get_record(), indent=4, default=str))
