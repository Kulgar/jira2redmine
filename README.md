<h1>This project is looking for a new maintainer</h1>
I don't have the time, and worse, the incentive, to maintain this project anymore.

If you are interested in taking over, please contact me personally.


jira2redmine
============

Script for import from JIRA to redmine

for more information please look at: http://www.redmine.org/issues/1385

## How to

Copy `migrate_jira.rake` to `lib/tasks` in your *Redmine* directory 

Unzip the Jira backup file into `tmp`

Change the variables in top of the file to reflect the backup files

```
  ENTITIES_FILE = 'tmp/JIRA-backup-XXXXXXXX/entities.xml'
  JIRA_ATTACHMENTS_DIR = 'tmp/JIRA-backup-XXXXXXXX/data/attachments'
  $JIRA_WEB_URL = 'https://<unix-url>.atlassian.net'
```

and the execute the following:

```
rake jira_migration:test_all_migrations RAILS_ENV="production"
rake jira_migration:do_all_migrations RAILS_ENV="production"
```

On first `test_all_migrations` a `map_jira_to_redmine.yml` is created and needs to be updated, before running the next migration command (or the test again) 

If a user is created by the migration, the default password will be `Pa$$w0rd`, and needs to be changed on first login.
