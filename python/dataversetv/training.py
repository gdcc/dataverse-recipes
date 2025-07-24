#!/usr/bin/env python3
import urllib.request as urlrequest
from urllib.parse import urlparse
import csv
import io

# Crowdsourced data.
crowd_url = 'https://docs.google.com/spreadsheets/d/1uVk_57Ek_A49sLZ5OKdI6QASKloWNzykni3kcYNzpxA/export?gid=0&format=tsv'
response = urlrequest.urlopen(crowd_url)
crowd_string = response.read().decode(response.info().get_param('charset') or 'utf-8')
reader = csv.DictReader(io.StringIO(crowd_string), delimiter="\t")
rows = [row for row in reader]
for row in rows:
    if row['Training material'] != '1':
        continue
    date = row['Date']
    title = row['Title']
    installation = row['Installation']
    type = row['Type']
    target = row['Target audience']
    link = ''
    youtube_id = row['YouTube ID']
    if youtube_id:
        link = 'https://www.youtube.com/watch?v=' + youtube_id
    non_youtube_url = row['Non-YouTube landing page']
    if non_youtube_url:
        link = non_youtube_url
    print('Date: ' + date + '; Title: ' + title + '; Installation: ' + installation + '; Type: ' + type + '; Target Audience: ' + target + '; Languages: EN; Links: ' + link)

