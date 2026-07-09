import sys
with open("index.html", "r") as f:
    content = f.read()

# Let's check for any hardcoded "1.6" in index.html and update it if needed.
# Actually, the user's javascript already does:
# document.querySelectorAll('.version-label').forEach(el => el.textContent = 'v' + APP_VERSION);
# document.querySelectorAll('.version-badge').forEach(el => el.textContent = '🎉 Now on v' + APP_VERSION);
# So I just needed to update APP_VERSION to 1.8. Did I do that?
# Let's verify.
print("Is 1.6 present?", "1.6" in content)
