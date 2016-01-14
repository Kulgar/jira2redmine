<h1>New maintainer</h1>
I will do my best to continue maintaining this project. :)


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
