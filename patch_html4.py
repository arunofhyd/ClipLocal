import sys
with open("index.html", "r") as f:
    content = f.read()

# Wait, where is 1.6?
print(content.find("1.6"))
print(content[content.find("1.6")-50:content.find("1.6")+50])
