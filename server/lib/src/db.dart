import 'package:postgres/postgres.dart';

import 'config.dart';

Pool<void> openPool(Config config) => Pool.withEndpoints(
      [config.database],
      settings: PoolSettings(
        maxConnectionCount: 10,
        sslMode: config.databaseTls ? SslMode.require : SslMode.disable,
      ),
    );

/// Each entry is one migration; statements run in a single transaction.
/// Append only — never edit an entry that has shipped.
final migrations = <List<String>>[
  [
    // The previous Swift/Vapor backend used the same database. Its tables are
    // kept (moved with their indexes into their own schema), not dropped.
    'CREATE SCHEMA IF NOT EXISTS legacy_vapor',
    for (final table in ['_fluent_migrations', 'feedback', 'visits', 'reviews', 'friendships', 'users', 'doener_places'])
      'ALTER TABLE IF EXISTS public.$table SET SCHEMA legacy_vapor',
    '''CREATE TABLE places (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      google_place_id text NOT NULL UNIQUE,
      name text NOT NULL,
      latitude double precision NOT NULL,
      longitude double precision NOT NULL,
      address text,
      postal_code text,
      city text,
      opening_hours text,
      synced_at timestamptz NOT NULL DEFAULT now(),
      created_at timestamptz NOT NULL DEFAULT now()
    )''',
    'CREATE INDEX places_lat_lon ON places (latitude, longitude)',
    '''CREATE TABLE search_tiles (
      tile_key text PRIMARY KEY,
      searched_at timestamptz NOT NULL
    )''',
    '''CREATE TABLE users (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      email text NOT NULL UNIQUE,
      display_name text NOT NULL,
      live_place_id uuid REFERENCES places (id) ON DELETE SET NULL,
      live_until timestamptz,
      live_food_type text,
      created_at timestamptz NOT NULL DEFAULT now()
    )''',
    'CREATE UNIQUE INDEX users_display_name ON users (lower(display_name))',
    '''CREATE TABLE login_requests (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      email text NOT NULL,
      code_hash text NOT NULL,
      token_hash text NOT NULL UNIQUE,
      attempts int NOT NULL DEFAULT 0,
      expires_at timestamptz NOT NULL,
      used_at timestamptz,
      created_at timestamptz NOT NULL DEFAULT now()
    )''',
    'CREATE INDEX login_requests_email ON login_requests (email, created_at)',
    '''CREATE TABLE sessions (
      token_hash text PRIMARY KEY,
      user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
      expires_at timestamptz NOT NULL,
      created_at timestamptz NOT NULL DEFAULT now()
    )''',
    '''CREATE TABLE reviews (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
      place_id uuid NOT NULL REFERENCES places (id) ON DELETE CASCADE,
      rating int NOT NULL CHECK (rating BETWEEN 1 AND 5),
      sauce_rating int CHECK (sauce_rating BETWEEN 1 AND 5),
      fleisch_rating int CHECK (fleisch_rating BETWEEN 1 AND 5),
      brot_rating int CHECK (brot_rating BETWEEN 1 AND 5),
      text text,
      special_note text,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      UNIQUE (user_id, place_id)
    )''',
    'CREATE INDEX reviews_place ON reviews (place_id)',
    '''CREATE TABLE visits (
      id uuid PRIMARY KEY,
      user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
      place_id uuid NOT NULL REFERENCES places (id) ON DELETE CASCADE,
      visited_at timestamptz NOT NULL,
      comment text,
      food_type text,
      created_at timestamptz NOT NULL DEFAULT now()
    )''',
    'CREATE INDEX visits_user ON visits (user_id, visited_at)',
    'CREATE INDEX visits_place ON visits (place_id)',
    '''CREATE TABLE friendships (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      requester_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
      addressee_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
      status text NOT NULL CHECK (status IN ('pending', 'accepted')),
      created_at timestamptz NOT NULL DEFAULT now(),
      CHECK (requester_id <> addressee_id)
    )''',
    // One friendship per pair, regardless of who asked first.
    '''CREATE UNIQUE INDEX friendships_pair ON friendships
      (LEAST(requester_id, addressee_id), GREATEST(requester_id, addressee_id))''',
    '''CREATE TABLE feedback (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid REFERENCES users (id) ON DELETE SET NULL,
      message text NOT NULL,
      screenshot bytea,
      app_version text,
      build_number text,
      platform text,
      created_at timestamptz NOT NULL DEFAULT now()
    )''',
    '''CREATE TABLE shop_reports (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      user_id uuid REFERENCES users (id) ON DELETE SET NULL,
      name text NOT NULL,
      hint text,
      latitude double precision,
      longitude double precision,
      note text,
      created_at timestamptz NOT NULL DEFAULT now()
    )''',
    // Community aggregates are computed on read — no denormalized counters to keep in sync.
    '''CREATE VIEW place_view AS
      SELECT p.*, s.avg_rating, COALESCE(s.review_count, 0) AS review_count, n.special_note
      FROM places p
      LEFT JOIN (
        SELECT place_id, avg(rating)::float8 AS avg_rating, count(*)::int AS review_count
        FROM reviews GROUP BY place_id
      ) s ON s.place_id = p.id
      LEFT JOIN LATERAL (
        SELECT special_note FROM reviews r
        WHERE r.place_id = p.id AND r.special_note IS NOT NULL
        ORDER BY r.updated_at DESC LIMIT 1
      ) n ON true''',
  ],
  [
    // Personal invite link: whoever opens it and signs in becomes a friend.
    'ALTER TABLE users ADD COLUMN invite_code text UNIQUE',
    // Whose link brought a new account in — to measure how invites spread.
    'ALTER TABLE users ADD COLUMN invited_by uuid REFERENCES users (id) ON DELETE SET NULL',
  ],
  [
    // Google tile searches per user and day — caps what a single account can cost.
    '''CREATE TABLE daily_searches (
      user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
      day date NOT NULL,
      count int NOT NULL,
      PRIMARY KEY (user_id, day)
    )''',
  ],
  [
    // Diet and expert mode belong to the account, so the web app knows them too.
    "ALTER TABLE users ADD COLUMN diet text NOT NULL DEFAULT 'all' CHECK (diet IN ('all', 'vegetarian', 'vegan'))",
    'ALTER TABLE users ADD COLUMN expert_mode boolean NOT NULL DEFAULT false',
    // The main score per diet is derived from the ratings when a review is
    // saved (Diet.score). A review about falafel alone has no Döner score.
    'ALTER TABLE reviews ALTER COLUMN rating DROP NOT NULL',
    'ALTER TABLE reviews ADD COLUMN vegetarian_rating int CHECK (vegetarian_rating BETWEEN 1 AND 5)',
    'ALTER TABLE reviews ADD COLUMN vegan_rating int CHECK (vegan_rating BETWEEN 1 AND 5)',
    // What the reviewer says about the place; per place the majority counts.
    'ALTER TABLE reviews ADD COLUMN vegan_options boolean',
    'ALTER TABLE reviews ADD COLUMN ayran_homemade boolean',
    'ALTER TABLE reviews ADD COLUMN ingredients text[]',
    'ALTER TABLE reviews ADD COLUMN meat text',
    'ALTER TABLE reviews ADD COLUMN skewer text',
    'ALTER TABLE reviews ADD COLUMN bread text',
    // Ratings beyond sauce, meat and bread: falafel, pizza, ayran …
    '''CREATE TABLE review_items (
      review_id uuid NOT NULL REFERENCES reviews (id) ON DELETE CASCADE,
      item text NOT NULL,
      rating int NOT NULL CHECK (rating BETWEEN 1 AND 5),
      PRIMARY KEY (review_id, item)
    )''',
    'CREATE INDEX review_items_item ON review_items (item)',
    // Google announces openings: FUTURE_OPENING with a date ("YYYY-MM-DD", or
    // "YYYY-MM" without a day), OPERATIONAL once the shop is open.
    'ALTER TABLE places ADD COLUMN business_status text',
    'ALTER TABLE places ADD COLUMN opening_date text',
    'ALTER TABLE places ADD COLUMN opened_on date',
    // Places that haven't opened yet only show up as announcements.
    'DROP VIEW place_view',
    '''CREATE VIEW place_view AS
      SELECT p.*, s.avg_rating, COALESCE(s.review_count, 0) AS review_count,
        s.avg_vegetarian, COALESCE(s.vegetarian_count, 0) AS vegetarian_count,
        s.avg_vegan, COALESCE(s.vegan_count, 0) AS vegan_count, s.vegan_options
      FROM places p
      LEFT JOIN (
        SELECT place_id,
          avg(rating)::float8 AS avg_rating, count(rating)::int AS review_count,
          avg(vegetarian_rating)::float8 AS avg_vegetarian, count(vegetarian_rating)::int AS vegetarian_count,
          avg(vegan_rating)::float8 AS avg_vegan, count(vegan_rating)::int AS vegan_count,
          CASE WHEN count(*) FILTER (WHERE vegan_options) > count(*) FILTER (WHERE NOT vegan_options) THEN true
               WHEN count(*) FILTER (WHERE NOT vegan_options) > count(*) FILTER (WHERE vegan_options) THEN false
          END AS vegan_options
        FROM reviews GROUP BY place_id
      ) s ON s.place_id = p.id
      WHERE p.business_status IS DISTINCT FROM 'FUTURE_OPENING'
    ''',
  ],
  [
    // One photo per review, kept out of `reviews` so `r.*` stays small. A new
    // photo gets a new id, which makes its URL cacheable for good.
    '''CREATE TABLE review_photos (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      review_id uuid NOT NULL UNIQUE REFERENCES reviews (id) ON DELETE CASCADE,
      content_type text NOT NULL,
      data bytea NOT NULL,
      created_at timestamptz NOT NULL DEFAULT now()
    )''',
  ],
];

Future<void> migrate(Pool<void> db) async {
  await db.execute('CREATE TABLE IF NOT EXISTS schema_migrations '
      '(version int PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())');
  final applied = await db.execute('SELECT coalesce(max(version), 0) FROM schema_migrations');
  final current = applied.first.first as int;

  for (var version = current + 1; version <= migrations.length; version++) {
    await db.runTx((tx) async {
      for (final statement in migrations[version - 1]) {
        await tx.execute(statement);
      }
      await tx.execute(Sql.named('INSERT INTO schema_migrations (version) VALUES (@v)'), parameters: {'v': version});
    });
  }
}
