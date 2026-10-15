<?php

$pdo = new PDO('sqlite::memory:');
$version = $pdo->query('SELECT sqlite_version()')->fetchColumn();

if (version_compare($version, '3.46.0', '<')) {
    throw new RuntimeException("Unsupported PDO SQLite: {$version}");
}

if (SQLite3::version()['versionString'] !== $version) {
    throw new RuntimeException('PDO and SQLite3 load different SQLite versions.');
}

// Older SQLite parsers overflow on deeply nested Laravel regional queries.
$pdo->exec('CREATE TABLE smoke (value INTEGER)');
$pdo->exec('INSERT INTO smoke VALUES (42)');
$query = 'SELECT value FROM smoke';
for ($depth = 0; $depth < 40; $depth++) {
    $query = "SELECT * FROM ({$query})";
}

$statement = $pdo->query($query);
if ($statement->fetchColumn() !== 42 || $statement->getColumnMeta(0)['table'] !== 'smoke') {
    throw new RuntimeException('Nested SQLite queries or PDO column metadata failed.');
}

echo "SQLite {$version}: nested query and column metadata passed.\n";
