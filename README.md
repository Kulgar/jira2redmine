<h1>This project is looking for a new maintainer</h1>
I don't have the time, and worse, the incentive, to maintain this project anymore.

If you are interested in taking over, please contact me personally.


jira2redmine
============

Script for import from JIRA to redmine

for more information please look at: http://www.redmine.org/issues/1385

## How to

Copy `migrate_jira.rake` to `lib/tasks` in your *Redmine* directory and the execute the following:

```
rake jira_migration:test_all_migrations RAILS_ENV="production"
rake jira_migration:do_all_migrations RAILS_ENV="production"
```
