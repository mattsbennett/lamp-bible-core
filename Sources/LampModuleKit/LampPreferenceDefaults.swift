/// The starting values the apps have to agree on.
///
/// A preference that travels between devices cannot have a different default
/// on each platform. Whichever device writes first silently changes what the
/// other does, and the person who never touched the setting is left with a
/// value they appear to have chosen. The reading-plan reminder is the plain
/// case: a phone defaulting to the evening and a Mac defaulting to the morning
/// means installing the Mac moves the phone's reminder, or the reverse,
/// depending only on which one synced first.
///
/// `plans.reminder.hour` and `plans.reminder.minute` are shared preferences
/// (`LampSharedPreferenceLedger`); `plans.wordsPerMinute` travels in a portable
/// backup (`LampPortableSettingsCodec`). Both kinds need one default, so both
/// are here.
///
/// These are the phone's values. It has shipped them since 1.2.0, so it is the
/// expensive side to move.
public enum LampPreferenceDefaults {
    /// The pace a reading plan's day is estimated at.
    ///
    /// Also the pace the phone reads aloud at, so an estimate matches what a
    /// listener actually hears rather than how fast the words could be skimmed.
    public static let plansWordsPerMinute = 183

    /// When the daily reading reminder fires, as hour and minute: 18:30.
    ///
    /// Evening rather than morning, which is when a plan's reading is more
    /// often outstanding rather than already done.
    public static let plansReminderHour = 18
    public static let plansReminderMinute = 30
}
