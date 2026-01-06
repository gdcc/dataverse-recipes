import requests
import xml.etree.ElementTree as ET
import csv

# --- Configuration ---
BASE_URL = "https://yourinstancedomainname/oai"
METADATA_PREFIX = "oai_dc"
OUTPUT_CSV = "dataverse_oai_records.csv"
VERBOSE = True

# --- Namespaces ---
NS = {
    'oai': 'http://www.openarchives.org/OAI/2.0/',
    'oai_dc': 'http://www.openarchives.org/OAI/2.0/oai_dc/',
    'dc': 'http://purl.org/dc/elements/1.1/'
}

def fetch_oai_records():
    records = []
    params = {
        "verb": "ListRecords",
        "metadataPrefix": METADATA_PREFIX
    }
    batch = 1

    while True:
        if VERBOSE:
            print(f"📦 Fetching batch {batch}...")

        response = requests.get(BASE_URL, params=params)
        response.raise_for_status()

        root = ET.fromstring(response.content)

        for record in root.findall('.//oai:record', NS):
            records.append(record)

        token = root.find('.//oai:resumptionToken', NS)
        if token is not None and token.text:
            params = {
                "verb": "ListRecords",
                "resumptionToken": token.text.strip()
            }
            batch += 1
        else:
            if VERBOSE:
                print("✅ All records fetched.")
            break

    return records

def extract_text(parent, xpath):
    elems = parent.findall(xpath, NS)
    return [e.text.strip() for e in elems if e.text]

def write_csv(records):
    if VERBOSE:
        print(f"📝 Writing {len(records)} records to CSV...")

    with open(OUTPUT_CSV, "w", newline="", encoding="utf-8") as csvfile:
        writer = csv.writer(csvfile)
        writer.writerow([
            "identifier",
            "datestamp",
            "title",
            "creator",
            "publisher",
            "description",
            "subjects",
            "date",
            "contributor",
            "type"
        ])

        for rec in records:
            header = rec.find('oai:header', NS)
            metadata = rec.find('oai:metadata', NS)

            if metadata is None:
                continue

            dc = metadata.find('oai_dc:dc', NS)
            if dc is None:
                continue

            writer.writerow([
                header.findtext('oai:identifier', default="", namespaces=NS),
                header.findtext('oai:datestamp', default="", namespaces=NS),
                "; ".join(extract_text(dc, 'dc:title')),
                "; ".join(extract_text(dc, 'dc:creator')),
                "; ".join(extract_text(dc, 'dc:publisher')),
                " ".join(extract_text(dc, 'dc:description')),
                "; ".join(extract_text(dc, 'dc:subject')),
                "; ".join(extract_text(dc, 'dc:date')),
                "; ".join(extract_text(dc, 'dc:contributor')),
                "; ".join(extract_text(dc, 'dc:type'))
            ])

    if VERBOSE:
        print(f"✅ Done: Saved to {OUTPUT_CSV}")

if __name__ == "__main__":
    records = fetch_oai_records()
    write_csv(records)
