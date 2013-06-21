express = require('express')
coffeeify = require('coffeeify')
derby = require('derby')
racerBrowserChannel = require('racer-browserchannel')
LiveDbMongo = require('livedb-mongo').LiveDbMongo
MongoStore = require('connect-mongo')(express)
app = require('../app')
error = require('./serverError')
mongoskin = require('mongoskin')
publicDir = require('path').join __dirname + '/../../public'

auth = require 'derby-auth'
priv = require './private.coffee'
middleware = require './middleware'
{helpers} = require("habitrpg-shared")

# Infinite stack trace
Error.stackTraceLimit = Infinity if process.env.NODE_ENV is 'development'

# Set up our express app

expressApp = module.exports = express()

# Get Redis configuration
if process.env.REDIS_HOST
  redis = require("redis").createClient(process.env.REDIS_PORT, process.env.REDIS_HOST)
  redis.auth process.env.REDIS_PASSWORD
else
  redis = require("redis").createClient()
redis.select process.env.REDIS_DB or 7

# Get Mongo configuration
mongoUrl = process.env.NODE_DB_URI or "mongodb://localhost:27017/habitrpg"
mongo = mongoskin.db(mongoUrl + "?auto_reconnect",
  safe: true
)

# The store creates models and syncs data
store = derby.createStore(
  db: new LiveDbMongo(mongo)
  redis: redis
)

store.on 'bundle', (browserify) ->
  vendorScripts = [
    "jquery-ui-1.10.2/jquery-1.9.1"
    "jquery.cookie.min"
    "bootstrap/js/bootstrap.min"
    "jquery.bootstrap-growl.min"
    "datepicker/js/bootstrap-datepicker"
    "bootstrap-tour/bootstrap-tour"
  ]
  # FIXME check if mobile
  vendorScripts = vendorScripts.concat [
    "jquery-ui-1.10.2/ui/jquery.ui.core"
    "jquery-ui-1.10.2/ui/jquery.ui.widget"
    "jquery-ui-1.10.2/ui/jquery.ui.mouse"
    "jquery-ui-1.10.2/ui/jquery.ui.sortable"
    "sticky"
  ]
  vendorScripts.forEach (s) -> browserify.add "#{publicDir}/vendor/#{s}.js"
  # Add support for directly requiring coffeescript in browserify bundles
  browserify.transform coffeeify

# Authentication setup
strategies =
  facebook:
    strategy: require("passport-facebook").Strategy
    conf:
      clientID: process.env.FACEBOOK_KEY
      clientSecret: process.env.FACEBOOK_SECRET
options =
  domain: process.env.BASE_URL || 'http://localhost:3000'
  allowPurl: true
  schema: helpers.newUser(true)

# This has to happen before our middleware stuff
auth.store.init(store) #setup
#auth.store.basicUserAccess(store) # we don't want default access
require('./store')(store) # setup our own accessControl

expressApp
  .use(middleware.allowCrossDomain)
  .use(express.favicon())
  .use(express.compress()) # Gzip dynamically
  .use(app.scripts(store)) # Respond to requests for application script bundles
  .use(express['static'](publicDir)) # Serve static files from the public directory

# Session middleware
  .use(express.cookieParser())
  .use(express.session(
    secret: process.env.SESSION_SECRET or "YOUR SECRET HERE"
    store: new MongoStore(
      url: mongoUrl
      safe: true
    )
  ))

# Parse form data
  .use(express.bodyParser())
  .use(express.methodOverride())

#.use(everyauth.middleware(autoSetupRoutes: false))

# Add browserchannel client-side scripts to model bundles created by store,
# and return middleware for responding to remote client messages
  .use(racerBrowserChannel(store))
# Add req.getModel() method
  .use(store.modelMiddleware())

# Authentication
  .use(auth.middleware(strategies, options))

# Custom Translations
  .use(middleware.translate)

# API should be hit before all other routes
  .use('/api/v1', require('./api').middleware)
  .use('/api/v2', require('./apiv2').middleware)
  .use(require('./deprecated').middleware)

# Other custom middlewares
  .use(middleware.splash) # Show splash page for newcomers
  .use(priv.middleware)
  .use(middleware.view)

# Create an express middleware from the app's routes
  .use(app.router())
  .use(require('./static').middleware) #custom static middleware
  .use error()

priv.routes(expressApp)

# SERVER-SIDE ROUTES #

expressApp.all "*", (req, res, next) ->
  next "404: " + req.url