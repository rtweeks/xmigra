# XMigra [![Gem Version](https://badge.fury.io/rb/xmigra.svg)](http://badge.fury.io/rb/xmigra)

DevOps tool for your relational database

## What Does It Do?

* Integrates version control with database schema management.
* Enhances access artifact (stored procedure, view, and user defined function) 
  development:
    * Allows each artifact to be defined in a separate file, giving easy
      access to version history.
    * Scripts artifact definitions in order (and removal in reverse order) by
      declared dependencies.
    * Makes records of all artifacts created, allowing removal by subsequent
      scripts without _a priori_ knowledge of all previously created artifacts.
      (This is really helpful when you roll back to an earlier version of the
      schema source documents that do not even contain the names of more
      recently added objects.)
* Facilitates multi-branch development by allowing database schema changes on
  any branch and providing tools to identify and resolve conflicts in the 
  migration chain.
* Provides _development_ and _production_ modes for script generation to ensure
  production databases remain in well-documented states.
* Generates [idempotent][idempotence] upgrade scripts that use only SQL
  (flavored specifically for a selected database).
* Integrates the SQL _you_ provide into the upgrade script intelligently --
  you don't have to learn a whole new language to define your schema objects!
* Provides tools for gathering information on the history of migration-modified
  database objects (tables, namespaces, etc.).
* Allows tracking table structures declaratively, even suggesting SQL to effect
  supported changes to tables, which can integrate with database access layer
  testing.

## What Systems Does It Work With?

**Ruby**
* Versions 2.0+

**Version Control**
* Subversion
* Git

**Databases**
* Microsoft SQL Server (2005 and later)
* PostgreSQL (tested on 9.3, should work for 8.4 or later)

## Tell Me More!

XMigra brings the tools and ideas of software development to the world of
database schemas.  Specifically, this tool enables you to keep your database
schema parts under version control in much the same way you keep your software
source code under version control.

XMigra also removes the tedious and error-prone task of organizing the order
of stored procedure, view, and user-defined function definition with dependency
declarations.  XMigra will remove and create these access artifacts in an
order that satisfies the dependencies you declare.  With the information it
persists about the artifacts it has created, XMigra can effectively remove any
that you remove from your schema source -- no need for you to track the names
of database objects you long ago discarded.

Multiple branch development -- whether simultaneous by multiple developers or
for agilely shifting focus to between priorities -- is fully supported by XMigra
with tools to properly identify and resolve conflicts in the migration chain.
XMigra comes with support for multiple release chains (i.e. _branch upgrades_)
baked right in, too!

XMigra has a modular design, allowing extension to additional version control
and database systems with only minor, if any, changes to the central framework.

Get the code and run `xmigra overview` for the tool's own rundown on
all of its exciting features. The wiki for this project also contains a [fairly
comprehensive tutorial](https://github.com/rtweeks/xmigra/wiki/Tutorial).

## Installation

<!-- Creative Commons Attribution-ShareAlike 4.0 International License -->
<a rel="license" href="http://creativecommons.org/licenses/by-sa/4.0/"><img alt="Creative Commons License" style="border-width:0" src="http://i.creativecommons.org/l/by-sa/4.0/88x31.png" /></a><br />
  <span xmlns:dct="http://purl.org/dc/terms/" property="dct:title">XMigra</span>
  by <span xmlns:cc="http://creativecommons.org/ns#" property="cc:attributionName">Next IT Corporation</span> and <span xmlns:cc="http://creativecommons.org/ns#" property="cc:attributionName">Richard T. Weeks</span>
  is licensed under a <a rel="license" href="http://creativecommons.org/licenses/by-sa/4.0/">Creative Commons Attribution-ShareAlike 4.0 International License
</a>.

Add this line to your application's Gemfile:

    gem 'xmigra'

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install xmigra

## Usage

XMigra is bundled with its own documentation.  To view it, run:

    $ xmigra help

or:

    $ xmigra overview

## Contributing

1. Fork it ( http://github.com/rtweeks/xmigra/fork )
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request



  [idempotence]: http://stackoverflow.com/a/1077421/160072 "Stack Overflow - What is an idempotent operation?"
