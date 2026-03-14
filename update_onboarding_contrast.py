import os

filepath = '/Users/sivek/Documents/SpendX/lib/screens/onboarding_screen.dart'
with open(filepath, 'r') as f:
    content = f.read()

# Replace all Colors.grey[400] with Colors.white70 in the onboarding screens
content = content.replace('Colors.grey[400]', 'Colors.white70')

with open(filepath, 'w') as f:
    f.write(content)

print("Updated Onboarding Contrast")
