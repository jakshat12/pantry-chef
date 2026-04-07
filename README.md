# 🍛 PantryChef

**PantryChef** is an AI-powered Android app that scans your grocery bills, manages your pantry inventory, and suggests personalized Indian vegetarian eggless recipes — all powered by Groq's Llama AI via a secure backend proxy.

---

## ✨ Features

### 📸 Smart Bill Scanning
- Take a photo or upload your grocery receipt
- **Groq Vision AI** (Llama 4 Scout) reads the bill and extracts only food item names
- Automatically filters out store name, address, prices, taxes, and payment info
- Works with any Canadian grocery store — FreshCo, Walmart, Costco, Loblaws, Iqbal, and more
- Falls back to on-device **Google ML Kit OCR** if server is unreachable

### 📦 Inventory Management
- View all pantry items as a clean list with quantity and unit
- Tap **+** / **−** buttons to quickly adjust quantities inline
- Edit item name, quantity, and unit (kg, g, L, ml, cup, tbsp, pcs, etc.)
- Add items manually with the floating **+** button
- Delete items with a single tap
- **Inventory persists** across sessions — saved locally on device

### 🍽️ AI Recipe Suggestions
- Powered by **Groq + Llama 3.3 (70B)** via a secure backend proxy
- Recipes are **Indian vegetarian and eggless**
- Each recipe includes:
  - Difficulty level (Easy / Medium / Hard)
  - Cook time
  - Approximate **protein** and **carbohydrate** content per serving
  - Ingredients used from your pantry
  - YouTube link to watch the recipe
- No API key needed — works out of the box for all users

### 🔍 Keyword Recipe Search
- Search for any recipe by keyword (e.g. "lauki paratha", "quick breakfast", "high protein")
- AI strictly matches results to your search term
- Search is pantry-aware — suggestions consider what you already have
- Tap "Back to pantry" to return to pantry-based suggestions

### 📊 Smart Sorting
Sort recipes by:
- ⏱️ **Cook Time** — quickest recipes first
- 💪 **Protein** — highest protein per serving first
- 🌾 **Carbs** — lowest carbs first (great for low-carb diets)

### 🧹 Smart Inventory Deduction
- After cooking, tap **"I cooked this"** on any recipe card
- Tell the app how many people you cooked for
- **Groq AI calculates** which ingredients were used and in what quantities
- Inventory is automatically updated — used items are decremented or removed

---

## 🏗️ Architecture

```
Android App (Flutter)
        │
        ▼
Render Proxy Server (Node.js)
        │
        ▼
Groq API (Llama 4 Scout / Llama 3.3 70B)
```

The Groq API key lives **only on the Render server** — never inside the APK. This keeps the key secure even if someone decompiles the app.

---

## 🛠️ Tech Stack

| Layer | Technology |
|-------|-----------|
| Framework | Flutter (Dart) |
| Platform | Android |
| OCR | Groq Vision (Llama 4 Scout) via proxy + Google ML Kit fallback |
| Recipe AI | Groq API (Llama 3.3 70B Versatile) via proxy |
| Backend Proxy | Node.js + Express on Render (free tier) |
| Local Storage | SharedPreferences |
| Image Picker | image_picker |
| URL Launcher | url_launcher |
| HTTP | http package |

---

## 🚀 Getting Started

### Prerequisites
- Flutter SDK 3.x+
- Android Studio
- Android device or emulator (API 21+)
- Free Groq API key from console.groq.com
- Free Render account from render.com

### 1. Set up the Backend Proxy

Deploy the included `index.js` to Render:
- Create a new Web Service on Render
- Connect your GitHub repo
- Set environment variable: `GROQ_API_KEY` = your Groq key
- Build command: `npm install`
- Start command: `npm start`

Your server URL will be: `https://your-server.onrender.com`

### 2. Configure the Flutter App

In `lib/main.dart`, update the server URL:
```dart
const SERVER_URL = "https://your-server.onrender.com/groq";
```

### 3. Install and Run

```bash
# Install dependencies
flutter pub get

# Run in debug mode
flutter run

# Build release APK
flutter build apk --release

# Install on connected device
flutter install
```

---

## 📱 How to Use

### Scanning a Grocery Bill
1. Tap the **Scan Bill** tab
2. Tap **Camera** or **Gallery**
3. Take or select a photo of your grocery receipt
4. Groq Vision AI extracts food items automatically (~2-3 seconds)
5. Review items — tap × to remove any incorrect ones
6. Tap **Add all to inventory**

### Getting Recipe Suggestions
1. Add items to your pantry via scan or manually
2. Tap the **Recipes** tab
3. AI generates personalized recipes based on your inventory
4. Sort by **Time**, **Protein**, or **Carbs** using the sort chips
5. Tap **Watch on YouTube** to see how to cook it
6. Tap **Refresh** to get a fresh set of suggestions

### Searching for Recipes
1. In the Recipes tab, type in the search bar
2. Enter any keyword — e.g. "paneer", "lauki paratha", "no onion"
3. Tap **Go** or press Enter
4. AI returns 5 recipes strictly matching your search
5. Tap **Back to pantry** to return to pantry-based suggestions

### Updating Inventory After Cooking
1. Find the recipe you cooked in the Recipes tab
2. Tap the green **"I cooked this"** button
3. Set how many people you cooked for using + / −
4. Tap **"I cooked this! Update inventory"**
5. AI deducts used ingredients from your pantry automatically

---

## 📦 Flutter Dependencies

```yaml
dependencies:
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.8
  google_mlkit_text_recognition: ^0.13.0
  image_picker: ^1.1.2
  url_launcher: ^6.3.0
  shared_preferences: ^2.3.0
  http: ^1.2.0
```

---

## 🔒 Security & Privacy

- **Groq API key** is stored only on the Render server — never in the APK
- **Basic token auth** (X-App-Token header) prevents unauthorized use of the proxy
- **Grocery bill photos** are processed by Groq Vision and not stored
- **Inventory data** is stored locally on the user's device only
- No user accounts, no tracking, no third-party analytics

---

## 🗺️ Roadmap

- [ ] Expiry date tracking for pantry items
- [ ] Shopping list generation for missing ingredients
- [ ] Meal planning (weekly schedule)
- [ ] Nutritional dashboard
- [ ] Multiple language support for receipts
- [ ] Share recipes with friends
- [ ] Dark mode
- [ ] iOS support

---

## 🤝 Contributing

Pull requests are welcome! For major changes, please open an issue first to discuss what you would like to change.

---

## 📄 License

This project is licensed under the MIT License.

---

## 🙏 Acknowledgements

- [Groq](https://groq.com) for blazing fast LLM inference
- [Google ML Kit](https://developers.google.com/ml-kit) for on-device OCR fallback
- [Flutter](https://flutter.dev) for the cross-platform framework
- [Render](https://render.com) for free backend hosting
