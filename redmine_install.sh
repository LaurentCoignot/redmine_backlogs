#/bin/bash

trap "cleanup" EXIT

cleanup()
{
  if [[ -e "$WORKSPACE/cuke.log" ]]; then
    sed '/^$/d' -i $WORKSPACE/cuke.log # empty lines
    sed 's/$//' -i $WORKSPACE/cuke.log # ^Ms at end of lines
    sed -r "s/\x1B\[([0-9]{1,2}(;[0-9]{1,2})?)?[m|K]//g"  -i $WORKSPACE/cuke.log # ansi coloring
  fi
}

export VERBOSE=yes

if [[ -e "$HOME/.backlogs.rc" ]]; then
  source "$HOME/.backlogs.rc"
fi

if [[ -z "$REDMINE_VER" ]]; then
  echo "You have not set REDMINE_VER"
  exit 1
fi

if [[ ! "$WORKSPACE" = /* ]] ||
   [[ ! "$PATH_TO_REDMINE" = /* ]] ||
   [[ ! "$PATH_TO_BACKLOGS" = /* ]];
then
  echo "You should set"\
       " REDMINE_VER, WORKSPACE, PATH_TO_REDMINE, PATH_TO_BACKLOGS"\
       " environment variables"
  echo "You set:"\
       "$WORKSPACE"\
       "$PATH_TO_REDMINE"\
       "$PATH_TO_BACKLOGS"
  exit 1;
fi

export CLUSTER_shared="features/shared-versions-burndown.feature features/shared-versions-chief_product_owner2.feature features/shared-versions-chief_product_owner.feature features/shared-versions.feature features/shared-versions-pblpage.feature features/shared-versions-positioning.feature features/shared-versions-scrum_master-dnd.feature features/shared-versions-team_member-dnd.feature"
export CLUSTER_burndown="features/burndown.feature features/cecilia_burndown.feature"
export CLUSTER_base="features/common.feature features/routes.feature features/duplicate_story.feature"
export CLUSTER_ui="features/settings.feature features/sidebar.feature features/ui.feature"
export CLUSTER_other=`ruby -e "puts (Dir['features/*.feature'] - ENV.keys.select{|k| k=~ /^CLUSTER_/}.collect{|k| ENV[k].split}.flatten).join(' ')"`

clusters()
{
  env | grep CLUSTER | awk -F= '{print $1}' | awk -F_ '{print "- bash -x ./redmine_install.sh -t _" $2}' | sort
}


export RAILS_ENV=test

case $REDMINE_VER in
  1.4.5)  export PATH_TO_PLUGINS=./vendor/plugins # for redmine < 2.0
          export GENERATE_SECRET=generate_session_store
          export MIGRATE_PLUGINS=db:migrate_plugins
          export REDMINE_TARBALL=https://github.com/edavis10/redmine/archive/$REDMINE_VER.tar.gz
          ;;
  2.1.4)  export PATH_TO_PLUGINS=./plugins # for redmine 2.1
          export GENERATE_SECRET=generate_secret_token
          export MIGRATE_PLUGINS=redmine:plugins:migrate
          export REDMINE_TARBALL=https://github.com/edavis10/redmine/archive/$REDMINE_VER.tar.gz
          ;;
  2.0.4)  export PATH_TO_PLUGINS=./plugins # for redmine 2.0
          export GENERATE_SECRET=generate_secret_token
          export MIGRATE_PLUGINS=redmine:plugins:migrate
          export REDMINE_TARBALL=https://github.com/edavis10/redmine/archive/$REDMINE_VER.tar.gz
          ;;
  master) export PATH_TO_PLUGINS=./plugins # for redmine 2.2
          export GENERATE_SECRET=generate_secret_token
          export MIGRATE_PLUGINS=redmine:plugins:migrate
          export REDMINE_TARBALL=https://github.com/edavis10/redmine/archive/$REDMINE_VER.tar.gz
          ;;
  v3.3.0) export PATH_TO_PLUGINS=./vendor/plugins
          export GENERATE_SECRET=generate_session_store
          export MIGRATE_PLUGINS=db:migrate:plugins
          export REDMINE_GIT_REPO=http://github.com/chiliproject/chiliproject.git
          export REDMINE_GIT_TAG=$REDMINE_VER
          ;;
  *)      echo "Unsupported platform $REDMINE_VER"
          exit 1
          ;;
esac

export BUNDLE_GEMFILE=$PATH_TO_REDMINE/Gemfile

clone_redmine()
{
  set -e # exit if clone fails
  rm -rf $PATH_TO_REDMINE
  if [ ! "$VERBOSE" = "yes" ]; then
    QUIET=--quiet
  fi
  #git clone -b master --depth=100 $QUIET $REDMINE_GIT_REPO $PATH_TO_REDMINE
  #cd $PATH_TO_REDMINE
  #if [ "$VERBOSE" = "yes" ]; then
  #  echo Available git tags in `pwd`:
  #  git tag
  #  ls .git
  #fi
  #git checkout $REDMINE_GIT_TAG
  wget $REDMINE_TARBALL -O- | tar -xvz --transform='s,^[^/]*,redmine,' --show-transformed -f -
}

run_tests()
{
  # exit if tests fail
  set -e

  cd $PATH_TO_REDMINE

  # create a link to cucumber features
  ln -sf $PATH_TO_BACKLOGS/features/ .

  mkdir -p coverage
  ln -sf `pwd`/coverage $WORKSPACE

  if [ "$VERBOSE" = "yes" ]; then
    TRACE=--trace
  fi
  # patch fixtures
  bundle exec rake redmine:backlogs:prepare_fixtures $TRACE

  # run cucumber
  if [ ! -n "${CUCUMBER_TAGS}" ];
  then
    CUCUMBER_TAGS="--tags ~@optional"
  fi

  if [ ! -n "${CUCUMBER_FLAGS}" ]; then
    if [ "$VERBOSE" = "yes" ]; then
      export CUCUMBER_FLAGS="${CUCUMBER_TAGS}"
    else
      export CUCUMBER_FLAGS="--format progress ${CUCUMBER_TAGS}"
    fi
  fi

  cluster="CLUSTER$1"
  CLUSTER="${!cluster}"
  FEATURE=$1
  if [ ! -e "$FEATURE" ]; then
    FEATURE="features/$FEATURE.feature"
  fi
  if [ ! -e "$FEATURE" ]; then
    FEATURE=""
  fi

  if [ ! "$CLUSTER" = "" ]; then
    TESTS="$CLUSTER"
    LOG="$WORKSPACE/cuke$1.log"
  elif [ -e "$FEATURE" ]; then
    TESTS="$FEATURE"
    LOG=`basename $FEATURE`
    LOG="$WORKSPACE/cuke.$LOG.log"
  else
    TEST="features"
    LOG=$WORKSPACE/cuke.log
  fi

  script -e -c "bundle exec cucumber $CUCUMBER_FLAGS $TESTS" -f $LOG
}

uninstall()
{
  set -e # exit if migrate fails
  cd $PATH_TO_REDMINE
  # clean up database
  if [ "$VERBOSE" = "yes" ]; then
    TRACE=--trace
  fi
  bundle exec rake $TRACE $MIGRATE_PLUGINS NAME=redmine_backlogs VERSION=0
}

run_install()
{
# exit if install fails
set -e

# cd to redmine folder
cd $PATH_TO_REDMINE
echo current directory is `pwd`

# create a link to the backlogs plugin
ln -sf $PATH_TO_BACKLOGS $PATH_TO_PLUGINS/redmine_backlogs

if [ "$CLEARDB" = "yes" ]; then
  DBNAME=`ruby -e "require 'yaml'; puts YAML::load(open('../database.yml'))['$RAILS_ENV']['database']"`
  DBTYPE=`ruby -e "require 'yaml'; puts YAML::load(open('../database.yml'))['$RAILS_ENV']['adapter']"`
  if [ "$DBTYPE" = "mysql2" ] || [ "$DBTYPE" = "mysql" ]; then
    mysqladmin -f -u root -p$DBROOTPW drop $DBNAME
    mysqladmin -u root -p$DBROOTPW create $DBNAME
  fi
fi

if [ "$DB_TO_RESTORE" = "" ]; then
  export story_trackers=Story
  export task_tracker=Task
else
  DBNAME=`ruby -e "require 'yaml'; puts YAML::load(open('../database.yml'))['$RAILS_ENV']['database']"`
  DBTYPE=`ruby -e "require 'yaml'; puts YAML::load(open('../database.yml'))['$RAILS_ENV']['adapter']"`
  if [ "$DBTYPE" = "mysql2" ] || [ "$DBTYPE" = "mysql" ]; then
    mysqladmin -f -u root -p$DBROOTPW drop $DBNAME
    mysqladmin -u root -p$DBROOTPW create $DBNAME
    mysql -u root -p$DBROOTPW $DBNAME < $DB_TO_RESTORE
  fi
fi

#ignore redmine-master's test-unit dependency, we need 1.2.3
sed -i -e 's=.*gem ["'\'']test-unit["'\''].*==g' ${PATH_TO_REDMINE}/Gemfile
# install gems
mkdir -p vendor/bundle
bundle install --path vendor/bundle

#sed -i -e "s/require 'rake\/gempackagetask'/require 'rubygems\/package_task'/" -e 's/require "rake\/gempackagetask"/require "rubygems\/package_task"/' `find . -type f -exec grep -l 'require.*rake.gempackagetask' {} \;` README.rdoc
sed -i -e 's/fail "GONE"/#fail "GONE"/' `find . -type f -exec grep -l 'fail "GONE"' {} \;` README.rdoc

if [ "$VERBOSE" = "yes" ]; then echo 'Gems installed'; fi

# copy database.yml
cp $WORKSPACE/database.yml config/
RUBYVER=`ruby -v | awk '{print $2}' | awk -F. '{print $1"."$2}'`
if [ "$RUBYVER" = "1.8" ]; then
  sed -i -e 's/mysql2/mysql/g' config/database.yml
fi

if [ "$VERBOSE" = "yes" ]; then
  export TRACE=--trace
fi

# run redmine database migrations
if [ "$VERBOSE" = "yes" ]; then echo 'Migrations'; fi
bundle exec rake db:migrate $TRACE

# install redmine database
if [ "$VERBOSE" = "yes" ]; then echo 'Load defaults'; fi
bundle exec rake redmine:load_default_data REDMINE_LANG=en $TRACE

if [ "$VERBOSE" = "yes" ]; then echo 'Tokens'; fi
# generate session store/secret token
bundle exec rake $GENERATE_SECRET $TRACE

# run backlogs database migrations
if [ "$VERBOSE" = "yes" ]; then echo 'Plugin migrations'; fi
bundle exec rake $MIGRATE_PLUGINS $TRACE

# install backlogs
if [ "$VERBOSE" = "yes" ]; then echo 'Backlogs install'; fi
bundle exec rake redmine:backlogs:install labels=no $TRACE

if [ "$VERBOSE" = "yes" ]; then echo 'Done!'; fi
}

while getopts :irtuc opt
do case "$opt" in
  r)  clone_redmine; exit 0;;
  i)  run_install;  exit 0;;
  t)  run_tests $2;  exit 0;;
  u)  uninstall;  exit 0;;
  c)  clusters;  exit 0;;
  [?]) echo "i: install; r: clone redmine; t: run tests; u: uninstall";;
  esac
done
