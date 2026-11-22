class CategoryClassifier {
  static final Map<String, List<String>> expenseRules = {
    'Food': [
      'zomato', 'swiggy', 'bundl', 'restaurant', 'cafe', 'eat', 'food', 'dine',
      'pizza', 'burger', 'dominos', 'mcdonalds', 'kfc', 'subway', 'burger king',
      'pizza hut', 'faasos', 'behrouz', 'box8', 'freshmenu', 'eatsure', 'rebel foods',
      'ovenstory', 'oven story', 'mojo pizza', 'biryani', 'kitchen', 'canteen',
      'mess', 'dhaba', 'bakery', 'blinkit', 'zepto', 'instamart', 'lunch', 'dinner',
      'breakfast', 'snack', 'tea', 'coffee', 'juice', 'ice cream', 'cake', 'tiffin',
      'chicken', 'mutton', 'fish', 'paneer', 'thali', 'parcel',
      'takeaway', 'delivery', 'noodles', 'pasta', 'sandwich', 'wrap',
      'shawarma', 'momos', 'chaat', 'pani puri', 'dosa', 'idli',
      'starbucks', 'chaayos', 'chai point', 'third wave', 'blue tokai',
      'haldiram', 'barbeque nation', 'bikanervala', 'a2b', 'adyar ananda bhavan',
      'saravana bhavan', 'anjappar', 'wow momo', 'wendys', 'chicking', 'wok',
      'ccd', 'cafe coffee day', 'mcdonald',
      'hotel arya', 'hotel ', 'bhavan', 'annapoorna', 'mess', 'food chain',
      'vvm food', 'thattukada', 'saravana', 'woodlands', 'sagar',
    ],
    'Transport': [
      'uber', 'ola', 'fuel', 'petrol', 'petroleum', 'diesel', 'cng', 'bus', 'train',
      'metro', 'rapido', 'namma yatri', 'nammayatri', 'indrive', 'blusmart', 'auto', 'cab', 'taxi',
      'irctc', 'redbus', 'abhibus', 'toll', 'fastag', 'fastag recharge', 'park+ fastag', 'parking', 'park+', 'parkplus', 'nhai',
      'commute', 'ride', 'rickshaw', 'bike fuel', 'car fuel', 'car wash', 'service',
      'vehicle service', 'tyre', 'puncture', 'rto', 'traffic fine',
      'challan', 'driving', 'license', 'emission test',
      'hpcl', 'bpcl', 'iocl', 'petrol pump', 'fuel station', 'filling station',
      'city fuel', 'fuel st', 'petrol st',
      'hindustan petroleum', 'bharat petroleum', 'indian oil', 'nayara', 'shell', 'jio-bp',
      'statiq', 'ather grid', 'zeon charging', 'bolt earth', 'ev charging',
      'chalo', 'dmrc', 'bmrc', 'bmrcl', 'cmrl', 'mmrcl', 'delhi metro', 'bangalore metro',
      'namma metro', 'mumbai metro', 'chennai metro', 'kochi metro',
    ],
    'Groceries': [
      'supermarket', 'mart', 'grocery', 'store', 'bigbasket', 'dmart',
      'supermarket grocery', 'kiranakart', 'blink commerce', 'bb daily', 'bbdaily',
      'freshtohome', 'fresh to home', 'licious', 'reliance', 'reliance fresh', 'reliance smart',
      'smart bazaar', 'more', 'more retail', 'more supermarket', 'spencers',
      'nature basket', 'jiomart', 'otipy', 'vegetables', 'fruits', 'provision',
      'kirana', 'milk', 'egg', 'bread', 'rice', 'wheat', 'flour', 'atta', 'dal', 'oil',
      'sugar', 'salt', 'spice', 'masala', 'curd', 'butter', 'ghee',
      'cheese', 'paneer', 'fresh', 'organic', 'amul', 'mother dairy',
      'country delight', 'countrydelight', 'daily needs', 'household',
    ],
    'Bills': [
      'electricity', 'water', 'bill', 'recharge', 'postpaid', 'prepaid',
      'mobile', 'broadband', 'internet', 'gas', 'cylinder', 'piped gas',
      'bharat gas', 'indane', 'hp gas', 'act fibernet', 'hathway',
      'asianet broadband', 'excitel', 'dth', 'tata sky', 'tata play', 'dish tv',
      'dishtv', 'sun direct', 'airtel', 'jio', 'vi ', 'bsnl',
      'electricity board', 'bescom', 'mseb', 'msedcl', 'mahadiscom', 'kseb',
      'tneb', 'tangedco', 'cesc', 'torrent power', 'adani electricity', 'tata power',
      'igl', 'mgl', 'indraprastha gas', 'mahanagar gas',
      'phone bill', 'wifi', 'landline', 'sewage', 'municipal',
      'property tax', 'water tax', 'bbps', 'billdesk',
    ],
    'Shopping': [
      'amazon', 'flipkart', 'myntra', 'ajio', 'meesho', 'nykaa',
      'tata cliq', 'tatacliq', 'tata unistore', 'tataunistore', 'mycliq',
      'snapdeal', 'shopping', 'purchase', 'online',
      'croma', 'reliance digital', 'vijay sales', 'clothes', 'apparel',
      'shoes', 'footwear', 'bata', 'gadget', 'electronics', 'furniture',
      'decor', 'accessories', 'watch', 'bag', 'purse', 'wallet',
      'decathlon', 'zudio', 'westside', 'trent', 'max fashion', 'pantaloons',
      'lifestyle', 'shoppers stop', 'ikea', 'pepperfry', 'urban ladder',
      'wakefit', 'sleepycat', 'h&m', 'zara', 'uniqlo', 'snitch', 'bewakoof', 'souled store',
      'cosmetics', 'makeup', 'skincare', 'perfume', 'shampoo',
      'soap', 'detergent', 'cleaning', 'home decor', 'curtain',
      'bedsheet', 'pillow', 'mattress', 'kitchen appliance',
      'headphone', 'earphone', 'charger', 'cable', 'cover', 'case',
      'fan', 'cooler', 'heater', 'iron', 'mixer', 'blender',
    ],
    'Subscriptions': [
      'netflix', 'spotify', 'prime', 'hotstar', 'disney', 'youtube',
      'apple', 'apple services', 'google play', 'icloud', 'amazon prime', 'zee5',
      'sonyliv', 'jiocinema', 'playstation', 'steam', 'subscription', 'renewal', 'membership',
      'annual plan', 'monthly plan', 'premium', 'pro plan',
      'chatgpt', 'openai', 'claude', 'anthropic', 'perplexity', 'midjourney',
      'notion', 'canva', 'figma', 'adobe', 'microsoft 365',
      'google one', 'dropbox', 'vpn', 'nordvpn', 'expressvpn',
      'linkedin premium', 'medium', 'substack',
    ],
    'Health': [
      'hospital', 'pharmacy', 'clinic', 'doctor', 'medical', 'medicine',
      'apollo', 'medplus', 'netmeds', 'pharmeasy', '1mg', 'tata 1mg', 'tata health',
      'lab test', 'diagnostic', 'dental', 'optical', 'gym', 'yoga',
      'fitness', 'workout', 'health checkup', 'blood test', 'xray',
      'dr lal', 'metropolis', 'thyrocare', 'lenskart',
      'scan', 'surgery', 'operation', 'therapy', 'physiotherapy',
      'ayurveda', 'homeopathy', 'spectacle', 'lens', 'eye care',
      'skin care', 'dermatologist', 'psychiatrist', 'counselling',
      'mental health', 'wellness', 'supplement', 'vitamin', 'protein',
      'cult fit', 'cure fit', 'cultfit', 'curefit', 'practo', 'healthify',
    ],
    'Travel': [
      'flight', 'hotel', 'booking', 'makemytrip', 'goibibo', 'cleartrip',
      'yatra', 'oyo', 'airbnb', 'indigo', 'spicejet', 'vistara',
      'air india', 'ixigo', 'easemytrip', 'resort', 'vacation',
      'air arabia', 'emirates', 'etihad', 'flydubai', 'qatar airways', 'gulf air',
      'singapore airlines', 'akasa air', 'saudia', 'oman air',
      'holiday', 'trip', 'tour', 'trek', 'camping', 'backpack',
      'visa', 'passport', 'luggage', 'suitcase', 'travel bag',
      'forex', 'currency exchange', 'travel insurance', 'lounge',
      'airport', 'railway', 'station', 'sleeper', 'tatkal',
      'bus ticket', 'train ticket', 'flight ticket', 'boarding pass',
      'sight seeing', 'sightseeing', 'museum', 'monument', 'temple',
      'pilgrimage', 'darshan', 'mandir', 'church', 'mosque',
    ],
    'Education': [
      'school', 'college', 'university', 'tuition', 'course', 'class',
      'udemy', 'coursera', 'unacademy', 'byju', 'vedantu', 'exam',
      'book', 'stationery', 'notebook', 'pen', 'pencil', 'fees',
      'admission', 'coaching', 'library', 'certification', 'degree',
      'diploma', 'workshop', 'seminar', 'conference', 'webinar',
      'skillshare', 'edx', 'khan academy', 'whitehat', 'coding',
      'programming', 'upsc', 'neet', 'jee', 'gate', 'cat',
      'ielts', 'toefl', 'gre', 'gmat', 'study material', 'textbook',
    ],
    'Entertainment': [
      'movie', 'cinema', 'pvr', 'inox', 'pvr inox', 'bookmyshow', 'district',
      'cinepolis', 'event', 'ticket', 'gaming', 'steam', 'play store', 'app store',
      'game', 'concert', 'show', 'comedy', 'standup', 'theatre', 'drama',
      'amusement park', 'water park', 'zoo', 'aquarium', 'bowling', 'arcade',
      'pool', 'billiards', 'karaoke', 'party', 'outing', 'pub', 'bar',
      'club', 'lounge', 'disc', 'nightclub', 'celebration',
      'birthday', 'anniversary', 'gathering', 'hangout', 'picnic',
      'beach', 'park', 'garden', 'playground', 'escape room',
      'vr experience', 'paintball', 'go karting', 'laser tag',
    ],
    'Insurance': [
      'insurance', 'premium', 'lic', 'policy', 'policybazaar', 'policy bazaar',
      'acko', 'digit', 'health insurance', 'term plan', 'cover', 'icici lombard',
      'hdfc ergo', 'star health', 'care health', 'niva bupa', 'max bupa',
      'life insurance', 'vehicle insurance', 'car insurance', 'bike insurance',
      'home insurance', 'travel insurance', 'accidental cover', 'critical illness',
      'bajaj allianz', 'sbi life', 'kotak life', 'tata aia',
      'new india assurance', 'oriental insurance',
    ],
    'EMI': [
      'emi', 'installment', 'equated monthly', 'loan emi', 'auto debit',
      'home loan', 'car loan', 'personal loan', 'education loan',
      'credit card emi', 'no cost emi', 'bajaj emi', 'hdfc emi',
      'loan repayment', 'mortgage',
    ],
    'Rent': [
      'rent', 'house rent', 'flat rent', 'pg', 'hostel', 'landlord',
      'maintenance', 'society', 'room rent', 'office rent', 'lease',
      'co-working', 'coworking', 'wework', 'shared space',
      'security deposit', 'caution deposit', 'brokerage', 'broker',
      'painting', 'repair', 'plumber', 'electrician', 'carpenter',
      'pest control', 'deep cleaning', 'house cleaning', 'maid',
      'cook', 'servant', 'watchman', 'guard',
    ],
    'Family': [
      'family', 'parents', 'mother', 'father', 'mom', 'dad',
      'amma', 'appa', 'mummy', 'papa', 'brother', 'sister',
      'wife', 'husband', 'spouse', 'son', 'daughter', 'kids',
      'children', 'baby', 'child', 'grandparent', 'grandmother',
      'grandfather', 'uncle', 'aunt', 'cousin', 'nephew', 'niece',
      'in-law', 'family support', 'pocket money', 'allowance',
      'school fees', 'tuition fees', 'daycare', 'creche', 'nanny',
      'babysitter', 'diaper', 'formula', 'baby food', 'toys',
      'relative', 'wedding', 'marriage', 'engagement', 'function',
      'ceremony', 'pooja', 'puja', 'housewarming', 'grihapravesh',
      'festival', 'diwali', 'holi', 'eid', 'christmas', 'onam',
      'pongal', 'rakhi', 'rakshabandhan', 'gift', 'present',
    ],
    'Personal Care': [
      'salon', 'haircut', 'hair', 'spa', 'massage', 'facial',
      'grooming', 'barber', 'parlour', 'parlor', 'beauty',
      'manicure', 'pedicure', 'waxing', 'threading', 'tattoo',
      'piercing', 'laundry', 'dry clean', 'ironing', 'tailor',
      'stitching', 'alteration',
    ],
    'Charity': [
      'donation', 'charity', 'ngo', 'trust', 'foundation',
      'temple donation', 'zakat', 'tithe', 'offering', 'help',
      'crowdfunding', 'fundraiser', 'relief fund', 'orphanage',
      'old age home', 'seva', 'daan', 'contribution',
    ],
    'Pets': [
      'pet', 'dog', 'cat', 'vet', 'veterinary', 'pet food',
      'pet shop', 'grooming', 'kennel', 'pet insurance',
      'paws', 'muddy paws', 'huft', 'heads up for tails', 'tailwaggers',
      'pet care', 'pet clinic',
      'dog food', 'cat food', 'fish tank', 'aquarium', 'bird',
    ],
    'Others': [
      'atm cash withdrawal', 'atm withdrawal', 'cash withdrawal', 'atm cash wdl',
      'cash wdl', 'state bank atm', 'sbi atm', 'hdfc atm', 'icici atm',
      'axis atm', 'kotak atm', 'canara atm', 'bob atm', 'pnb atm',
      'nfs atm', 'atm', 'stationery', 'post office', 'speed post',
      'courier', 'xerox', 'photocopy', 'printing', 'miscellaneous',
    ],
  };

  static final Map<String, List<String>> incomeRules = {
    'Salary': [
      'salary', 'payroll', 'credited by', 'monthly salary', 'pay credit',
      'wage', 'stipend', 'compensation', 'ctc', 'take home',
      'net pay', 'gross pay', 'employer',
    ],
    'Freelance': [
      'client payment', 'project', 'invoice', 'consulting', 'freelance',
      'contract', 'gig', 'commission', 'retainer', 'milestone payment',
      'upwork', 'fiverr', 'toptal', 'freelancer',
    ],
    'Investment': [
      'dividend', 'interest', 'mutual fund', 'fd maturity',
      'fixed deposit', 'returns', 'capital gain', 'profit',
      'sip', 'stock', 'share', 'bond', 'ppf', 'nps', 'epf',
      'gold', 'crypto', 'trading', 'realized gain', 'unrealized',
      'zerodha', 'groww', 'kuvera', 'coin', 'smallcase',
      'angel one', 'upstox', 'dhan', 'indmoney', 'etmoney',
    ],
    'Refund': [
      'refund', 'reversal', 'cashback', 'return amount', 'chargeback',
      'reimbursement', 'claim settled', 'insurance claim',
      'tax refund', 'gst refund', 'excess payment', 'adjustment',
    ],
    'Rental Income': [
      'rental income', 'rent received', 'tenant', 'lease income',
      'property income', 'room rent received', 'sublease',
    ],
    'Business': [
      'business income', 'sales', 'revenue', 'profit', 'collection',
      'receivable', 'payment received', 'customer payment',
      'shop income', 'store income',
    ],
    'Other Income': [
      'received', 'credit', 'transfer from', 'gift', 'reward',
      'bonus', 'incentive', 'prize', 'lottery', 'winning',
      'cashback', 'coupon', 'voucher', 'rebate', 'subsidy',
      'scholarship', 'grant', 'pension', 'annuity', 'inheritance',
    ],
  };

  static String? detect({required String text, required String type}) {
    final lower = text.toLowerCase();
    final rules = type == 'income' ? incomeRules : expenseRules;

    // Prioritize longest keyword match to ensure specific multi-word rules
    // (e.g. 'tata unistore', 'grocery store', 'petrol pump') beat generic short tokens (e.g. 'store').
    String? bestCategory;
    int bestLength = 0;

    for (final entry in rules.entries) {
      for (final keyword in entry.value) {
        if (lower.contains(keyword)) {
          if (keyword.length > bestLength) {
            bestLength = keyword.length;
            bestCategory = entry.key;
          }
        }
      }
    }

    return bestCategory;
  }
}
