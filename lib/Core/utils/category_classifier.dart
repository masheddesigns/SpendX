class CategoryClassifier {
  static final Map<String, List<String>> expenseRules = {
    'Food': [
      'zomato', 'swiggy', 'restaurant', 'cafe', 'eat', 'food', 'dine',
      'pizza', 'burger', 'dominos', 'mcdonalds', 'kfc', 'subway',
      'biryani', 'kitchen', 'canteen', 'mess', 'dhaba', 'bakery',
      'blinkit', 'zepto', 'instamart', 'lunch', 'dinner', 'breakfast',
      'snack', 'tea', 'coffee', 'juice', 'ice cream', 'cake', 'tiffin',
      'chicken', 'mutton', 'fish', 'paneer', 'thali', 'parcel',
      'takeaway', 'delivery', 'noodles', 'pasta', 'sandwich', 'wrap',
      'shawarma', 'momos', 'chaat', 'pani puri', 'dosa', 'idli',
      'starbucks', 'chaayos', 'haldiram', 'barbeque nation',
      'ccd', 'cafe coffee day', 'mcdonald', 'chicking', 'wok',
    ],
    'Transport': [
      'uber', 'ola', 'fuel', 'petrol', 'diesel', 'bus', 'train',
      'metro', 'rapido', 'auto', 'cab', 'taxi', 'irctc', 'redbus',
      'toll', 'fastag', 'parking', 'nhai', 'commute', 'ride',
      'rickshaw', 'bike fuel', 'car fuel', 'car wash', 'service',
      'vehicle service', 'tyre', 'puncture', 'rto', 'traffic fine',
      'challan', 'driving', 'license', 'emission test',
    ],
    'Groceries': [
      'supermarket', 'mart', 'grocery', 'store', 'bigbasket', 'dmart',
      'reliance', 'more', 'spencers', 'nature basket', 'jiomart',
      'vegetables', 'fruits', 'provision', 'kirana', 'milk', 'egg',
      'bread', 'rice', 'wheat', 'flour', 'atta', 'dal', 'oil',
      'sugar', 'salt', 'spice', 'masala', 'curd', 'butter', 'ghee',
      'cheese', 'paneer', 'fresh', 'organic', 'amul', 'mother dairy',
      'country delight', 'daily needs', 'household',
    ],
    'Bills': [
      'electricity', 'water', 'bill', 'recharge', 'postpaid', 'prepaid',
      'mobile', 'broadband', 'internet', 'gas', 'cylinder', 'piped gas',
      'dth', 'tata sky', 'airtel', 'jio', 'vi ', 'bsnl',
      'electricity board', 'bescom', 'mseb', 'kseb', 'tneb',
      'phone bill', 'wifi', 'landline', 'sewage', 'municipal',
      'property tax', 'water tax',
    ],
    'Shopping': [
      'amazon', 'flipkart', 'myntra', 'ajio', 'meesho', 'nykaa',
      'tata cliq', 'snapdeal', 'shopping', 'purchase', 'online',
      'croma', 'reliance digital', 'vijay sales', 'clothes', 'apparel',
      'shoes', 'footwear', 'gadget', 'electronics', 'furniture',
      'decor', 'accessories', 'watch', 'bag', 'purse', 'wallet',
      'cosmetics', 'makeup', 'skincare', 'perfume', 'shampoo',
      'soap', 'detergent', 'cleaning', 'home decor', 'curtain',
      'bedsheet', 'pillow', 'mattress', 'kitchen appliance',
      'headphone', 'earphone', 'charger', 'cable', 'cover', 'case',
      'fan', 'cooler', 'heater', 'iron', 'mixer', 'blender',
    ],
    'Subscriptions': [
      'netflix', 'spotify', 'prime', 'hotstar', 'disney', 'youtube',
      'apple', 'google play', 'icloud', 'amazon prime', 'zee5',
      'sonyliv', 'jiocinema', 'subscription', 'renewal', 'membership',
      'annual plan', 'monthly plan', 'premium', 'pro plan',
      'chatgpt', 'notion', 'canva', 'figma', 'adobe', 'microsoft 365',
      'google one', 'dropbox', 'vpn', 'nordvpn', 'expressvpn',
      'linkedin premium', 'medium', 'substack',
    ],
    'Health': [
      'hospital', 'pharmacy', 'clinic', 'doctor', 'medical', 'medicine',
      'apollo', 'medplus', 'netmeds', 'pharmeasy', '1mg', 'tata health',
      'lab test', 'diagnostic', 'dental', 'optical', 'gym', 'yoga',
      'fitness', 'workout', 'health checkup', 'blood test', 'xray',
      'scan', 'surgery', 'operation', 'therapy', 'physiotherapy',
      'ayurveda', 'homeopathy', 'spectacle', 'lens', 'eye care',
      'skin care', 'dermatologist', 'psychiatrist', 'counselling',
      'mental health', 'wellness', 'supplement', 'vitamin', 'protein',
      'cult fit', 'cure fit', 'practo', 'healthify',
    ],
    'Travel': [
      'flight', 'hotel', 'booking', 'makemytrip', 'goibibo', 'cleartrip',
      'yatra', 'oyo', 'airbnb', 'indigo', 'spicejet', 'vistara',
      'air india', 'ixigo', 'easemytrip', 'resort', 'vacation',
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
      'movie', 'cinema', 'pvr', 'inox', 'bookmyshow', 'event', 'ticket',
      'gaming', 'play store', 'app store', 'game', 'concert', 'show',
      'comedy', 'standup', 'theatre', 'drama', 'amusement park',
      'water park', 'zoo', 'aquarium', 'bowling', 'arcade', 'pool',
      'billiards', 'karaoke', 'party', 'outing', 'pub', 'bar',
      'club', 'lounge', 'disc', 'nightclub', 'celebration',
      'birthday', 'anniversary', 'gathering', 'hangout', 'picnic',
      'beach', 'park', 'garden', 'playground', 'escape room',
      'vr experience', 'paintball', 'go karting', 'laser tag',
    ],
    'Insurance': [
      'insurance', 'premium', 'lic', 'policy', 'health insurance',
      'term plan', 'cover', 'icici lombard', 'hdfc ergo',
      'star health', 'max bupa', 'life insurance', 'vehicle insurance',
      'car insurance', 'bike insurance', 'home insurance',
      'travel insurance', 'accidental cover', 'critical illness',
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
      'dog food', 'cat food', 'fish tank', 'aquarium', 'bird',
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

    for (final entry in rules.entries) {
      for (final keyword in entry.value) {
        if (lower.contains(keyword)) {
          return entry.key;
        }
      }
    }

    return null;
  }
}
