import shutil
import tempfile
import urllib.request
import gzip
from datetime import datetime
import os.path
from urllib.error import HTTPError
from dateutil.relativedelta import *
import ssl, smtplib

currentmonth=datetime.now().replace(day=1) + relativedelta(days=-1)
processmonth=currentmonth

filename="/opt/pidreporting/dcpidreportstate"
if os.path.exists(filename):
  with open(filename) as f:
    line=next(f)
    processmonth = datetime.strptime(line.strip('\n'),"%m_%Y")
    processmonth = processmonth + relativedelta(months=+1)

# Configuration variables
receivers = "admin@mydataverse.org,support@myinstitution.org"  # Enter receiver address
doi_account = "GDCC.YOUR_ACCOUNT"  # Replace with your DataCite account prefix
dataverse_base_url = "https://data.yourdataverse.org"  # Replace with your Dataverse installation URL

# mail config
port = 465  # For SSL
smtp_server = "" #Enter your SMTP server address, e.g. email-smtp.us-east-1.amazonaws.com
sender_email = ""  # Enter your address
username = ""
password = ""

message = "Subject: DataCite DOI Resolution Failure Reports\nTo: " + receivers + "\n\n"

found=True
somereports=False
while (processmonth <= currentmonth) and found:
  monthstr = processmonth.strftime("%m_%Y")

  try:
    with urllib.request.urlopen('https://stats.datacite.org/stats/resolution-report/resolutions_' + monthstr + '.html') as response:
      with tempfile.NamedTemporaryFile(delete=False) as tmp_file:
        gzip_fd = gzip.GzipFile(fileobj=response)
        shutil.copyfileobj(gzip_fd, tmp_file)
    message = message + "Report for " + monthstr +"\n\nHits\tDOI\tURI\n(Note: clicking links will record new failures unless these are drafts)\n"
    with open(tmp_file.name) as html:
      for line in html:
        if doi_account in line:
          rightlist=False;
          done=False
          for line in html:
            if "</ol>" in line:
              rightlist=True;
            elif ("<ol>" in line) and rightlist:
              somereports=True
              for line in html:
                if line.startswith("<a "):
                  failpid = "doi:" + line.split('"')[1].split("doi.org/")[1]
                  linewithcount=next(html)
                  linewithcount=next(html)
                  message=message + "\n" + linewithcount.replace(')','(').split("(")[1] + "\t" + failpid + "\t"  + dataverse_base_url + "/dataset.xhtml?persistentId=" + failpid
                elif "</ol>" in line:
                  done=True
                  break
              if done:
                break
            if done:
              break
    with open(filename, "w") as f:
      f.write(processmonth.strftime("%m_%Y"))
    message= message + "\n\n"
    processmonth=processmonth + relativedelta(months=+1)
  except urllib.error.HTTPError as err:
    found=False
if not somereports:
    message=message + "No new monthly reports from DataCite. Next report expected: " + monthstr + "\n\n"


context = ssl.create_default_context()
with smtplib.SMTP_SSL(smtp_server, port, context=context) as server:
    server.login(username, password)
    server.sendmail(sender_email, receivers.split(","), message)

