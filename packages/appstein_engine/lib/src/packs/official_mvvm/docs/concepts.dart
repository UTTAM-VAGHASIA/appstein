/// The parts of an official_mvvm app in plain words (spec §6.9): concept
/// text written once, here, and versioned with the pack. Each entry is the
/// part's name and what it is.
const mvvmConcepts = <String, String>{
  'Screen':
      'A widget that shows state and passes on what the user does. It holds '
      'no business logic.',
  'View model':
      'Holds the state of one screen and the actions the screen can run. It '
      'extends `ChangeNotifier`, and the screen rebuilds when it notifies.',
  'Repository':
      'The one place a kind of data lives, such as bookings or the '
      'signed-in user. It turns what services return into the app\'s own '
      'models and handles caching and errors.',
  'Service':
      'Wraps one outside source: an HTTP API, a plugin, local storage. It '
      'holds no state.',
  'Domain model and use case':
      "The app's own data types, and logic that several view models share.",
};
