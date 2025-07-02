import smtplib, ssl, datetime, os.path

# Configuration variables
# File paths
log_dir = "/usr/local/payara6/domains/domain1/logs"  # Replace with your log directory path

# Dataverse configuration
dataverse_base_url = "https://data.yourdataverse.org"  # Replace with your Dataverse installation URL

# Email configuration
receivers = "admin@mydataverse.org,support@myinstitution.org"  # Enter receiver addresses
port = 465  # For SSL
smtp_server = "smtp.example.com"  # Replace with your SMTP server
sender_email = "sender@example.com"  # Enter your address
username = "your_username"  # Replace with your SMTP username
password = "your_password"  # Replace with your SMTP password

blacklist=[]
blacklist.append("146.6.15.11") #UT Dorkbot / autoscan.infosec.utexas.edu


def numSort(s):
    return int(s[0:s.index("_")])


if os.path.exists(filename):
    d={}
    blcount=0
    with open(filename) as f:
        for line in f.readlines()[1:]:
            (pid, uri, method, ip, time)=line.split("\t")
            if pid not in d and ip not in blacklist:
                d[pid] = []
            if ip not in blacklist:
                d[pid].append(method + " " + uri + " from " + ip + " at " + time)
            else:
                blcount = blcount + 1

    l=[]
    for key in d:
        l.append(str(len(d[key])) + "_" + key)

    l.sort(reverse=True, key=numSort)

    message = message + "Hits\tDOI\tURI\n(Note: clicking links will record new failures unless these are drafts)\n"

    for val in l:
        doi = val[val.index("_")+1:]
        message = message + "\n" + str(numSort(val)) + "\t" + doi + "\t" + dataverse_base_url + "/dataset.xhtml?persistentId=" + doi

    message = message + "\n\nDetails:\n\n"

    if blcount is not 0:
        message = message + str(blcount) + "entries (not reported) from blacklisted IP addresses (e.g. UT Dorkbot)\n\n"
    for val in l:
        doi = val[val.index("_")+1:]
        message = message + doi + "\n\t" + "\n\t".join(d[doi]) + "\n"
else:
    message= message + "No Failures this month\n\n"

context = ssl.create_default_context()
with smtplib.SMTP_SSL(smtp_server, port, context=context) as server:
    server.login(username, password)
    server.sendmail(sender_email, receivers.split(","), message)

