# Copyright 2011 Salvatore Sanfilippo. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
# 
#    1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 
#    2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY SALVATORE SANFILIPPO ''AS IS'' AND ANY EXPRESS
# OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
# OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN
# NO EVENT SHALL SALVATORE SANFILIPPO OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
# INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF
# THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
# 
# The views and conclusions contained in the software and documentation are
# those of the authors and should not be interpreted as representing official
# policies, either expressed or implied, of Salvatore Sanfilippo.

require 'enumerator'
require 'app_config'
require 'rubygems'
require 'sequel'
require 'pg'
require 'page'
require 'sinatra'
require 'json'
require 'time'
require 'digest/sha1'
require 'digest/md5'
require 'comments'
require 'pbkdf2'
require 'openssl' if UseOpenSSL

Version = "0.10.0"

before do
    $aki_db = Sequel.connect(:adapter => 'postgres', :host => AkibanHost, :port => AkibanPort, :database => AkibanSchema) if !$aki_db
    Sequel::Postgres.client_min_messages = nil 
    Sequel::Postgres.force_standard_strings = false
    Sequel::Postgres.use_iso_date_format = false
    H = HTMLGen.new if !defined?(H)
    $user = nil
    auth_user(request.cookies['auth'])
end

get '/' do
    H.set_title "Top News - #{SiteName}"
    news,numitems = get_top_news
    H.page {
        H.h2 {"Top news"}+news_list_to_html(news)
    }
end

get '/rss' do
    content_type 'text/xml', :charset => 'utf-8'
    news,count = get_latest_news
    H.rss(:version => "2.0", "xmlns:atom" => "http://www.w3.org/2005/Atom") {
        H.channel {
            H.title {
                "#{SiteName}"
            } + " " +
            H.link {
                "#{request.env['rack.url_scheme']}://#{request.env['HTTP_HOST']}"
            } + " " +
            H.description {
                "Description pending"
            } + " " +
            news_list_to_rss(news)
        }
    }
end

get '/latest' do
    redirect '/latest/0'
end

get '/latest/:start' do
    start = params[:start].to_i
    H.set_title "Latest news - #{SiteName}"
    paginate = {
        :get => Proc.new {|start,count|
            get_latest_news(start,count)
        },
        :render => Proc.new {|item| news_to_html(item)},
        :start => start,
        :perpage => LatestNewsPerPage,
        :link => "/latest/$"
    }
    H.page {
        H.h2 {"Latest news - #{SiteName}"}
        H.section(:id => "newslist") {
            list_items(paginate)
        }
    }
end

get '/saved/:start' do
    redirect "/login" if !$user
    start = params[:start].to_i
    H.set_title "Saved news - #{SiteName}"
    paginate = {
        :get => Proc.new {|start,count|
            get_saved_news($user["id"],start,count)
        },
        :render => Proc.new {|item| news_to_html(item)},
        :start => start,
        :perpage => SavedNewsPerPage,
        :link => "/saved/$"
    }
    H.page {
        H.h2 {"Your saved news"}+
        H.section(:id => "newslist") {
            list_items(paginate)
        }
    }
end

get '/usercomments/:username/:start' do
    start = params[:start].to_i
    user = get_user_by_username(params[:username])
    halt(404,"Non existing user") if !user

    H.set_title "#{H.entities user["username"]} comments - #{SiteName}"
    paginate = {
        :get => Proc.new {|start,count|
            get_user_comments(user["id"],start,count)
        },
        :render => Proc.new {|comment|
            u = retrieve_user(comment[:user_id].to_i) || DeletedUser
            comment_to_html(comment,u)
        },
        :start => start,
        :perpage => UserCommentsPerPage,
        :link => "/usercomments/#{H.urlencode user["username"]}/$"
    }
    H.page {
        H.h2 {"#{H.entities user["username"]} comments"}+
        H.div("id" => "comments") {
            list_items(paginate)
        }
    }
end

get '/replies' do
    redirect "/login" if !$user
    comments,count = get_user_comments($user["id"],0,SubthreadsInRepliesPage)
    H.set_title "Your threads - #{SiteName}"
    H.page {
        H.h2 {"Your threads"}+
        H.div("id" => "comments") {
            aux = ""
            comments.each{|c|
                aux << render_comment_subthread(c)
            }
            aux
        }
    }
end

get '/login' do
    H.set_title "Login - #{SiteName}"
    H.page {
        H.div(:id => "login") {
            H.form(:name=>"f") {
                H.label(:for => "username") {"username"}+
                H.inputtext(:id => "username", :name => "username")+
                H.label(:for => "password") {"password"}+
                H.inputpass(:id => "password", :name => "password")+H.br+
                H.checkbox(:name => "register", :value => "1")+
                "create account"+H.br+
                H.submit(:name => "do_login", :value => "Login")
            }
        }+
        H.div(:id => "errormsg"){}+
        H.script() {'
            $(function() {
                $("form[name=f]").submit(login);
            });
        '}
    }
end

get '/submit' do
    redirect "/login" if !$user
    H.set_title "Submit a new story - #{SiteName}"
    H.page {
        H.h2 {"Submit a new story"}+
        H.div(:id => "submitform") {
            H.form(:name=>"f") {
                H.inputhidden(:name => "news_id", :value => -1)+
                H.label(:for => "title") {"title"}+
                H.inputtext(:id => "title", :name => "title", :size => 80, :value => (params[:t] ? H.entities(params[:t]) : ""))+H.br+
                H.label(:for => "url") {"url"}+H.br+
                H.inputtext(:id => "url", :name => "url", :size => 60, :value => (params[:u] ? H.entities(params[:u]) : ""))+H.br+
                "or if you don't have an url type some text"+
                H.br+
                H.label(:for => "text") {"text"}+
                H.textarea(:id => "text", :name => "text", :cols => 60, :rows => 10) {}+
                H.button(:name => "do_submit", :value => "Submit")
            }
        }+
        H.div(:id => "errormsg"){}+
        H.p {
            bl = "javascript:window.location=%22#{SiteUrl}/submit?u=%22+encodeURIComponent(document.location)+%22&t=%22+encodeURIComponent(document.title)"
            "Submitting news is simpler using the "+
            H.a(:href => bl) {
                "bookmarklet"
            }+
            " (drag the link to your browser toolbar)"
        }+
        H.script() {'
            $(function() {
                $("input[name=do_submit]").click(submit);
            });
        '}
    }
end

get '/logout' do
    if $user and check_api_secret
        update_auth_token($user["id"])
    end
    redirect "/"
end

get "/news/:news_id" do
    news = get_specific_news_by_query(params["news_id"])
    halt(404,"404 - This news does not exist.") if !news
    # Show the news text if it is a news without URL.
    if !news_domain(news)
        c = {
            "body" => news_text(news),
            "ctime" => news[:ctime],
            "user_id" => news[:user_id],
            "thread_id" => news[:id],
            "topcomment" => true
        }
        user = retrieve_user(news[:user_id].to_i) || DeletedUser
        top_comment = H.topcomment {comment_to_html(c,user)}
    else
        top_comment = ""
    end
    H.set_title "#{H.entities news[:title]} - #{SiteName}"
    H.page {
        H.section(:id => "newslist") {
            news_to_html(news)
        }+top_comment+
        if $user
            H.form(:name=>"f") {
                H.inputhidden(:name => "news_id", :value => news[:id])+
                H.inputhidden(:name => "comment_id", :value => -1)+
                H.inputhidden(:name => "parent_id", :value => -1)+
                H.textarea(:name => "comment", :cols => 60, :rows => 10) {}+H.br+
                H.button(:name => "post_comment", :value => "Send comment")
            }+H.div(:id => "errormsg"){}
        else
            H.br
        end +
        render_comments_for_news(news[:id].to_i)+
        H.script() {'
            $(function() {
                $("input[name=post_comment]").click(post_comment);
            });
        '}
    }
end

get "/comment/:news_id/:comment_id" do
    news = get_specific_news_by_query(params["news_id"])
    halt(404,"404 - This news does not exist.") if !news
    comment = get_specific_comment(params["news_id"], params["comment_id"])
    halt(404,"404 - This comment does not exist.") if !comment
    H.page {
        H.section(:id => "newslist") {
            news_to_html(news)
        }+
        render_comment_subthread(comment, H.h2 {"Replies"})
    }
end

def render_comment_subthread(comment,sep="")
    H.div(:class => "singlecomment") {
        u = retrieve_user(comment[:user_id].to_i) || DeletedUser
        comment_to_html(comment,u)
    }+H.div(:class => "commentreplies") {
        sep+
        render_comments_for_news(comment[:thread_id].to_i,comment[:id].to_i)
    }
end

get "/reply/:news_id/:comment_id" do
    redirect "/login" if !$user
    news = get_specific_news_by_query(params["news_id"])
    halt(404,"404 - This news does not exist.") if !news
    comment = get_specific_comment(params["news_id"], params["comment_id"])
    halt(404,"404 - This comment does not exist.") if !comment
    user = retrieve_user(comment[:user_id].to_i) || DeletedUser

    H.set_title "Reply to comment - #{SiteName}"
    H.page {
        news_to_html(news)+
        comment_to_html(comment,user)+
        H.form(:name=>"f") {
            H.inputhidden(:name => "news_id", :value => news[:id])+
            H.inputhidden(:name => "comment_id", :value => -1)+
            H.inputhidden(:name => "parent_id", :value => params["comment_id"])+
            H.textarea(:name => "comment", :cols => 60, :rows => 10) {}+H.br+
            H.button(:name => "post_comment", :value => "Reply")
        }+H.div(:id => "errormsg"){}+
        H.script() {'
            $(function() {
                $("input[name=post_comment]").click(post_comment);
            });
        '}
    }
end

get "/editcomment/:news_id/:comment_id" do
    redirect "/login" if !$user
    news = get_specific_news_by_query(params["news_id"])
    halt(404,"404 - This news does not exist.") if !news
    comment = get_specific_comment(params["news_id"], params["comment_id"])
    halt(404,"404 - This comment does not exist.") if !comment
    user = retrieve_user(comment[:user_id].to_i) || DeletedUser
    halt(500,"Permission denied.") if $user["id"].to_i != user["id"].to_i

    H.set_title "Edit comment - #{SiteName}"
    H.page {
        news_to_html(news)+
        comment_to_html(comment,user)+
        H.form(:name=>"f") {
            H.inputhidden(:name => "news_id", :value => news[:id])+
            H.inputhidden(:name => "comment_id",:value => params["comment_id"])+
            H.inputhidden(:name => "parent_id", :value => -1)+
            H.textarea(:name => "comment", :cols => 60, :rows => 10) {
                H.entities comment[:body]
            }+H.br+
            H.button(:name => "post_comment", :value => "Edit")
        }+H.div(:id => "errormsg"){}+
        H.note {
            "Note: to remove the comment remove all the text and press Edit."
        }+
        H.script() {'
            $(function() {
                $("input[name=post_comment]").click(post_comment);
            });
        '}
    }
end

get "/editnews/:news_id" do
    redirect "/login" if !$user
    news = get_specific_news_by_query(params["news_id"])
    halt(404,"404 - This news does not exist.") if !news
    halt(500,"Permission denied.") if $user["id"].to_i != news[:user_id].to_i

    if news_domain(news)
        text = ""
    else
        text = news_text(news)
        news[:url] = ""
    end
    H.set_title "Edit news - #{SiteName}"
    H.page {
        news_to_html(news)+
        H.div(:id => "submitform") {
            H.form(:name=>"f") {
                H.inputhidden(:name => "news_id", :value => news[:id])+
                H.label(:for => "title") {"title"}+
                H.inputtext(:id => "title", :name => "title", :size => 80,
                            :value => H.entities(news['title']))+H.br+
                H.label(:for => "url") {"url"}+H.br+
                H.inputtext(:id => "url", :name => "url", :size => 60,
                            :value => H.entities(news[:url]))+H.br+
                "or if you don't have an url type some text"+
                H.br+
                H.label(:for => "text") {"text"}+
                H.textarea(:id => "text", :name => "text", :cols => 60, :rows => 10) {
                    H.entities(text)
                }+H.br+
                H.checkbox(:name => "del", :value => "1")+
                "delete this news"+H.br+
                H.button(:name => "edit_news", :value => "Edit")
            }
        }+
        H.div(:id => "errormsg"){}+
        H.script() {'
            $(function() {
                $("input[name=edit_news]").click(submit);
            });
        '}
    }
end

get "/user/:username" do
    user = get_user_by_username(params[:username])
    halt(404,"Non existing user") if !user
    posted_news = user["articles"]
    posted_comments = user["comments"]
    H.set_title "#{H.entities user["username"]} - #{SiteName}"
    owner = $user && ($user["id"].to_i == user["id"].to_i)
    H.page {
        H.div(:class => "userinfo") {
            H.span(:class => "avatar") {
                email = user["email"] || ""
                digest = Digest::MD5.hexdigest(email)
                H.img(:src=>"http://gravatar.com/avatar/#{digest}?s=48&d=mm")
            }+" "+
            H.h2 {H.entities user["username"]}+
            H.pre {
                #H.entities user[:about]
            }+
            H.ul {
                H.li {
                    H.b {"created "}+str_elapsed(Time.parse(user["ctime"]).to_i)
                }+
                H.li {H.b {"karma "}+ "#{user["karma"]} points"}+
                H.li {H.b {"posted news "}+posted_news.to_s}+
                H.li {H.b {"posted comments "}+posted_comments.to_s}+
                if owner
                    H.li {H.a(:href=>"/saved/0") {"saved news"}}
                else "" end+
                H.li {
                    H.a(:href=>"/usercomments/"+H.urlencode(user["username"])+
                               "/0") {
                        "user comments"
                    }
                }
            }
        }+if owner
            H.br+H.form(:name=>"f") {
                H.label(:for => "email") {
                    "email (not visible, used for gravatar)"
                }+H.br+
                H.inputtext(:id => "email", :name => "email", :size => 40,
                            :value => user["email"] ? H.entities(user["email"]) : '')+H.br+
                H.label(:for => "password") {
                    "change password (optional)"
                }+H.br+
                H.inputpass(:name => "password", :size => 40)+H.br+
                #H.label(:for => "about") {"about"}+H.br+
                #H.textarea(:id => "about", :name => "about", :cols => 60, :rows => 10){
                #    H.entities(user['about'])
                #}+H.br+
                H.button(:name => "update_profile", :value => "Update profile")
            }+
            H.div(:id => "errormsg"){}+
            H.script() {'
                $(function() {
                    $("input[name=update_profile]").click(update_profile);
                });
            '}
        else "" end
    }
end

###############################################################################
# API implementation
###############################################################################

post '/api/logout' do
    content_type 'application/json'
    if $user and check_api_secret
        update_auth_token($user["id"])
        return {:status => "ok"}.to_json
    else
        return {
            :status => "err",
            :error => "Wrong auth credentials or API secret."
        }.to_json
    end
end

get '/api/login' do
    content_type 'application/json'
    if (!check_params "username","password")
        return {
            :status => "err",
            :error => "Username and password are two required fields."
        }.to_json
    end
    auth,apisecret = check_user_credentials(params[:username],
                                            params[:password])
    if auth 
        return {
            :status => "ok",
            :auth => auth,
            :apisecret => apisecret
        }.to_json
    else
        return {
            :status => "err",
            :error => "No match for the specified username / password pair."
        }.to_json
    end
end

post '/api/create_account' do
    content_type 'application/json'
    if (!check_params "username","password")
        return {
            :status => "err",
            :error => "Username and password are two required fields."
        }.to_json
    end
    if params[:password].length < PasswordMinLength
        return {
            :status => "err",
            :error => "Password is too short. Min length: #{PasswordMinLength}"
        }.to_json
    end
    auth,errmsg = create_user(params[:username],params[:password])
    if auth 
        return {:status => "ok", :auth => auth}.to_json
    else
        return {
            :status => "err",
            :error => errmsg
        }.to_json
    end
end

post '/api/submit' do
    content_type 'application/json'
    return {:status => "err", :error => "Not authenticated."}.to_json if !$user
    if not check_api_secret
        return {:status => "err", :error => "Wrong form secret."}.to_json
    end

    # We can have an empty url or an empty first comment, but not both.
    if (!check_params "title","news_id",:url,:text) or
                               (params[:url].length == 0 and
                                params[:text].length == 0)
        return {
            :status => "err",
            :error => "Please specify a news title and address or text."
        }.to_json
    end
    # Make sure the URL is about an acceptable protocol, that is
    # http:// or https:// for now.
    if params[:url].length != 0
        if params[:url].index("http://") != 0 and
           params[:url].index("https://") != 0
            return {
                :status => "err",
                :error => "We only accept http:// and https:// news."
            }.to_json
        end
    end
    if params[:news_id].to_i == -1
        #if submitted_recently
        #    return {
        #        :status => "err",
        #        :error => "You have submitted a story too recently, "+
        #        "please wait #{allowed_to_post_in_seconds} seconds."
        #    }.to_json
        #end
        news_id = insert_news(params[:title],params[:url],params[:text],
                              $user["id"])
    else
        news_id = edit_news(params[:news_id],params[:title],params[:url],
                            params[:text],$user["id"])
        if !news_id
            return {
                :status => "err",
                :error => "Invalid parameters, news too old to be modified "+
                          "or url recently posted."
            }.to_json
        end
    end
    return  {
        :status => "ok",
        :news_id => news_id.to_i
    }.to_json
end

post '/api/delnews' do
    content_type 'application/json'
    return {:status => "err", :error => "Not authenticated."}.to_json if !$user
    if not check_api_secret
        return {:status => "err", :error => "Wrong form secret."}.to_json
    end
    if (!check_params "news_id")
        return {
            :status => "err",
            :error => "Please specify a news title."
        }.to_json
    end
    if del_news(params[:news_id],$user["id"])
        return {:status => "ok", :news_id => -1}.to_json
    end
    return {:status => "err", :error => "News too old or wrong ID/owner."}.to_json
end

post '/api/votenews' do
    content_type 'application/json'
    return {:status => "err", :error => "Not authenticated."}.to_json if !$user
    if not check_api_secret
        return {:status => "err", :error => "Wrong form secret."}.to_json
    end
    # Params sanity check
    if (!check_params "news_id","vote_type") or (params["vote_type"] != "up" and
                                                 params["vote_type"] != "down")
        return {
            :status => "err",
            :error => "Missing news ID or invalid vote type."
        }.to_json
    end
    # Vote the news
    vote_type = params["vote_type"].to_sym
    karma,error = vote_news(params["news_id"].to_i,$user["id"],vote_type)
    if karma
        return { :status => "ok" }.to_json
    else
        return { :status => "err", 
                 :error => error }.to_json
    end
end

post '/api/postcomment' do
    content_type 'application/json'
    return {:status => "err", :error => "Not authenticated."}.to_json if !$user
    if not check_api_secret
        return {:status => "err", :error => "Wrong form secret."}.to_json
    end
    # Params sanity check
    if (!check_params "news_id","comment_id","parent_id",:comment)
        return {
            :status => "err",
            :error => "Missing news_id, comment_id, parent_id, or comment
                       parameter."
        }.to_json
    end
    info = insert_comment(params["news_id"].to_i,$user["id"],
                          params["comment_id"].to_i,
                          params["parent_id"].to_i,params["comment"])
    return {
        :status => "err",
        :error => "Invalid news, comment, or edit time expired."
    }.to_json if !info
    return {
        :status => "ok",
        :op => info['op'],
        :comment_id => info['comment_id'],
        :parent_id => params['parent_id'],
        :news_id => params['news_id']
    }.to_json
end

post '/api/updateprofile' do
    content_type 'application/json'
    return {:status => "err", :error => "Not authenticated."}.to_json if !$user
    if not check_api_secret
        return {:status => "err", :error => "Wrong form secret."}.to_json
    end
    if !check_params(:email, :password)
        return {:status => "err", :error => "Missing parameters."}.to_json
    end
    if params[:password].length > 0
        if params[:password].length < PasswordMinLength
            return {
                :status => "err",
                :error => "Password is too short. "+
                          "Min length: #{PasswordMinLength}"
            }.to_json
        end
        update_user_password($user["id"], hash_password(params[:password], 
                                                       $user["salt"]))
    end
    update_user_email($user["id"], params[:email][0..255])
    return {:status => "ok"}.to_json
end

post '/api/votecomment' do
    content_type 'application/json'
    return {:status => "err", :error => "Not authenticated."}.to_json if !$user
    if not check_api_secret
        return {:status => "err", :error => "Wrong form secret."}.to_json
    end
    # Params sanity check
    if (!check_params "comment_id","vote_type") or
                                            (params["vote_type"] != "up" and
                                             params["vote_type"] != "down")
        return {
            :status => "err",
            :error => "Missing comment ID or invalid vote type."
        }.to_json
    end
    # Vote the news
    vote_type = params["vote_type"].to_sym
    news_id,comment_id = params["comment_id"].split("-")
    if vote_comment(news_id.to_i,comment_id.to_i,$user["id"],vote_type)
        return { :status => "ok", :comment_id => params["comment_id"] }.to_json
    else
        return { :status => "err", 
                 :error => "Invalid parameters or duplicated vote." }.to_json
    end
end

get  '/api/getnews/:sort/:start/:count' do
    content_type 'application/json'
    sort = params[:sort].to_sym
    start = params[:start].to_i
    count = params[:count].to_i
    if not [:latest,:top].index(sort)
        return {:status => "err", :error => "Invalid sort parameter"}.to_json
    end
    return {:status => "err", :error => "Count is too big"}.to_json if count > APIMaxNewsCount

    start = 0 if start < 0
    getfunc = method((sort == :latest) ? :get_latest_news : :get_top_news)
    news,numitems = getfunc.call(start,count)
    news.each{|n|
        ['rank','score','user_id'].each{|field| n.delete(field)}
    }
    return { :status => "ok", :news => news, :count => numitems }.to_json
end

get  '/api/getcomments/:news_id' do
    content_type 'application/json'
    return {
        :status => "err",
        :error => "Wrong news ID."
    }.to_json if not get_specific_news_by_query(params[:news_id])
    thread = Comments.fetch_thread(params[:news_id])
    top_comments = []
    thread.each{|parent,replies|
        if parent.to_i == -1
            top_comments = replies
        end
        replies.each{|r|
            user = retrieve_user(r['user_id'].to_i) || DeletedUser
            r['username'] = user["username"]
            r['replies'] = thread[r['id']] || []
            if r['up']
                r['voted'] = :up if $user && r['up'].index($user["id"].to_i)
                r['up'] = r['up'].length
            end
            if r['down']
                r['voted'] = :down if $user && r['down'].index($user["id"].to_i)
                r['down'] = r['down'].length
            end
            ['id','thread_id','score','parent_id','user_id'].each{|f|
                r.delete(f)
            }
        }
    }
    return { :status => "ok", :comments => top_comments }.to_json
end

# Check that the list of parameters specified exist.
# If at least one is missing false is returned, otherwise true is returned.
#
# If a parameter is specified as as symbol only existence is tested.
# If it is specified as a string the parameter must also meet the condition
# of being a non empty string.
def check_params *required
    required.each{|p|
        params[p].strip! if params[p] and params[p].is_a? String
        if !params[p] or (p.is_a? String and params[p].length == 0)
            return false
        end
    }
    true
end

def check_api_secret
    return false if !$user
    params["apisecret"] and (params["apisecret"] == $user["apisecret"])
end

###############################################################################
# Navigation, header and footer.
###############################################################################

# Return the HTML for the 'replies' link in the main navigation bar.
# The link is not shown at all if the user is not logged in, while
# it is shown with a badge showing the number of replies for logged in
# users.
def replies_link
    return "" if !$user
    #count = $user['replies'] || 0
    count = 0
    H.a(:href => "/replies", :class => "replies") {
        "replies"+
        if count.to_i > 0
            H.sup {count}
        else "" end
    }
end

def application_header
    navitems = [    ["top","/"],
                    ["latest","/latest/0"],
                    ["submit","/submit"]]
    navbar = H.nav {
        navitems.map{|ni|
            H.a(:href=>ni[1]) {H.entities ni[0]}
        }.inject{|a,b| a+"\n"+b}+replies_link
    }
    rnavbar = H.nav(:id => "account") {
        if $user
            H.a(:href => "/user/"+H.urlencode($user["username"])) { 
                H.entities $user["username"]+" (#{$user["karma"]})"
            }+" | "+
            H.a(:href =>
                "/logout?apisecret=#{$user["apisecret"]}") {
                "logout"
            }
        else
            H.a(:href => "/login") {"login / register"}
        end
    }
    H.header {
        H.h1 {
            H.a(:href => "/") {H.entities SiteName}+" "+
            H.small {Version}
        }+navbar+" "+rnavbar
    }
end

def application_footer
    if $user
        apisecret = H.script() {
            "var apisecret = '#{$user["apisecret"]}';";
        }
    else
        apisecret = ""
    end
    if KeyboardNavigation == 1
        keyboardnavigation = H.script() {
            "setKeyboardNavigation();"
        }
    else
        keyboardnavigation = ""
    end
    H.footer {
        links = [
            ["source code", "http://github.com/posulliv/lamernews"],
            ["rss feed", "/rss"],
            ["twitter", FooterTwitterLink],
            ["google group", FooterGoogleGroupLink]
        ]
        links.map{|l| l[1] ?
            H.a(:href => l[1]) {H.entities l[0]} :
            nil
        }.select{|l| l}.join(" | ")
    }+apisecret+keyboardnavigation
end

################################################################################
# User and authentication
################################################################################

def validate_auth_token(auth_token)
  query = "select user_id from auth_details where auth_token = '#{auth_token}'"
  res = $aki_db[query]
  res.collect { |row|
    row.each { |k,v|
      return v
    }
  }
  return nil
end

def calculate_karma_values(karma_list)
  sum = 0
  latest_time = 0
  karma_list.each do |karma|
    sum = sum + karma["amount"].to_i
    if karma["ctime"].to_i > latest_time
      latest_time = karma["ctime"].to_i
    end
  end
  return sum, latest_time
end

def calculate_summary_values(user)
  # now calculate some karma related information
  # in particular, want to total karma and the time
  # when karma was last incremented
  user["karma"], user["karma_incr_time"] = calculate_karma_values(user[AkibanSchema+".karma"])
  # number of submitted comments
  user["comments"] = user[AkibanSchema+".comments"].length
  # number of submitted articles
  user["articles"] = user[AkibanSchema+".articles"].length
  # TODO - convert this from a SQL query to use nested 
  user["voted"] = get_user_article_votes(user["id"])
  # TODO - this is simply done so less re-writing of main app is needed
  user["apisecret"] = user[AkibanSchema+".auth_details"][0]["apisecret"]
  user["auth_token"] = user[AkibanSchema+".auth_details"][0]["auth_token"]
  return user
end

def retrieve_user(user_id)
  # enable nested result sets first
  $aki_db << "set OutputFormat = 'json'"
  ds = $aki_db["select ** from users where id = ?", user_id]
  # populate user object directly from this JSON
  user = {}
  ds.collect do |row|
    user = JSON.parse(row[:JSON])
  end
  # now disable nested reset sets
  $aki_db << "set OutputFormat = 'table'"
  return calculate_summary_values(user)
end

def retrieve_user_by_username(username)
  # enable nested result sets first
  $aki_db << "set OutputFormat = 'json'"
  ds = $aki_db["select ** from users where username = ?", username]
  # populate user object directly from this JSON
  user = {}
  ds.collect do |row|
    user = JSON.parse(row[:JSON])
  end
  # now disable nested reset sets
  $aki_db << "set OutputFormat = 'table'"
  return calculate_summary_values(user)
end

# Try to authenticate the user, if the credentials are ok we populate the
# $user global with the user information.
# Otherwise $user is set to nil, so you can test for authenticated user
# just with: if $user ...
#
# Return value: none, the function works by side effect.
def auth_user(auth)
    return if !auth
    id = validate_auth_token(auth)
    return if !id
    if ! $user
      $user = retrieve_user(id)
    end
end

# In Lamer News users get karma visiting the site.
# Increment the user karma by KarmaIncrementAmount if the latest increment
# was performed more than KarmaIncrementInterval seconds ago.
#
# Return value: none.
#
# Notes: this function must be called only in the context of a logged in
#        user.
#
# Side effects: the user karma is incremented and the $user hash updated.
def increment_karma_if_needed
      increment_user_karma_by($user["id"],KarmaIncrementAmount)
end

# Increment the user karma by the specified amount and make sure to
# update $user to reflect the change if it is the same user id.
def increment_user_karma_by(user_id,increment)
    query = "insert into karma (user_id, amount, ctime) values (#{user_id}, #{increment}, now())"
    $aki_db << query
    if $user and ($user["id"].to_i == user_id.to_i)
        $user["karma"] = $user["karma"].to_i + increment
    end
end

# Return the specified user karma.
def get_user_karma(user_id)
    return $user["karma"].to_i if $user and (user_id.to_i == $user["id"].to_i)
    total_karma = $aki_db["select sum(amount) from karma where user_id = #{id}"]
    total_karma.collect { |row|
      row.each { |k,v|
        karma = v
      }
    }
    karma ? karma.to_i : 0
end

# Return the hex representation of an unguessable 160 bit random number.
def get_rand
    rand = "";
    File.open("/dev/urandom").read(20).each_byte{|x| rand << sprintf("%02x",x)}
    rand
end

def update_user_password(user_id, new_password)
  $aki_db << "update users set password = '#{new_password}' where id = #{user_id}"
end

def update_user_email(user_id, new_email)
  $aki_db << "update users set email = '#{new_email}' where id = #{user_id}"
end

# check database whether given username already exists
def user_exists(username)
  #res = $aki_db["select count(*) from users where username = ?", username]
  res = $aki_db["select count(*) from users where username = '#{username}'"]
  res.collect { |row|
    row.each { |k,v|
      if v > 0
        return true
      end
    }
  }
  return false
end

# Create a new user with the specified username/password
#
# Return value: the function returns two values, the first is the
#               auth token if the registration succeeded, otherwise
#               is nil. The second is the error message if the function
#               failed (detected testing the first return value).
def create_user(username,password)
    if user_exists(username)
        return nil, "Username already exists, please try a different one."
    end
    #if rate_limit_by_ip(3600*15,"create_user",request.ip)
    #    return nil, "Please wait some time before creating a new user."
    #end
    auth_token = get_rand
    salt = get_rand
    hashed_passwd = hash_password(password, salt)
    api_secret = get_rand
    # do within 1 transaction
    $aki_db.transaction do
      query = "
        insert into users 
          (
           username, 
           salt, 
           password, 
           ctime
          )
        values 
          (
           '#{username}', 
           '#{salt}', 
           '#{hashed_passwd}',
           now()
          )"
      $aki_db << query
      query = "select id from users where username = '#{username}' and salt = '#{salt}' and password = '#{hashed_passwd}'"
      user_id = 0
      ds = $aki_db[query]
      ds.collect { |row|
        row.each { |k,v|
          user_id = v 
        }
      }
      query = "
        insert into auth_details
          (
           user_id,
           auth_token,
           apisecret
          )
        values
          (
           #{user_id},
           '#{auth_token}',
           '#{api_secret}'
          )"
      $aki_db << query
      query = "
        insert into karma
          (
            user_id,
            amount,
            ctime
          )
        values
          (
            #{user_id},
            #{UserInitialKarma},
            now()
          )"
      $aki_db << query
    end
    return auth_token, nil
end

# Update the specified user authentication token with a random generated
# one. This in other words means to logout all the sessions open for that
# user.
#
# Return value: on success the new token is returned. Otherwise nil.
# Side effect: the auth token is modified.
def update_auth_token(user_id)
    new_auth_token = get_rand
    query = "update auth_details set auth_token = '#{new_auth_token}' where user_id = #{user_id}"
    $aki_db << query
    return new_auth_token
end

# Turn the password into an hashed one, using PBKDF2 with HMAC-SHA1
# and 160 bit output.
def hash_password(password,salt)
    p = PBKDF2.new do |p|
        p.iterations = PBKDF2Iterations
        p.password = password
        p.salt = salt
        p.key_length = 160/8
    end
    p.hex_string
end

# Return the user from the username.
def get_user_by_username(username)
  if ! user_exists(username)
    return nil
  end
  return retrieve_user_by_username(username)
end

def get_user_article_votes(user_id)
  query = "
  select
    av.article_id
  from 
    article_votes av,
    votes v
  where
    v.id = av.vote_id and
    v.user_id = #{user_id}"
  res = []
  $aki_db.fetch(query) do |row|
    res[row[:article_id]] = true
  end
  return res
end

# get number of comments this user has submitted
def get_num_user_submitted_comments(user)
  query = "select count(*) from comments where user_id = #{user["id"]}"
  res = $aki_db[query]
  res.collect { |row|
    row.each { |k,v|
      return v
    }
  }
  return 0
end

# get number of news articles this user has submitted
def get_num_user_submitted_articles(user)
  query = "select count(*) from articles where user_id = #{user["id"]}"
  res = $aki_db[query]
  res.collect { |row|
    row.each { |k,v|
      return v
    }
  }
  return 0
end

# Check if the username/password pair identifies an user.
# If so the auth token and form secret are returned, otherwise nil is returned.
def check_user_credentials(username,password)
    user = get_user_by_username(username)
    return nil if !user
    hp = hash_password(password,user["salt"])
    (user[:password] == hp) ? [user["auth_token"],user["apisecret"]] : nil
end

# Has the user submitted a news story in the last `NewsSubmissionBreak` seconds?
def submitted_recently
    allowed_to_post_in_seconds > 0
end

# Indicates when the user is allowed to submit another story after the last.
def allowed_to_post_in_seconds
    $r.ttl("user:#{$user["id"]}:submitted_recently")
end

# Add the specified set of flags to the user.
# Returns false on error (non existing user), otherwise true is returned.
#
# Current flags:
# 'a'   Administrator.
# 'k'   Karma source, can transfer more karma than owned.
# 'n'   Open links to new windows.
#
def user_add_flags(user_id,flags)
    user = retrieve_user(user_id.to_i)
    return false if !user
    newflags = user["flags"]
    flags.each_char{|flag|
        newflags << flag if not user_has_flags?(user,flag)
    }
    # Note: race condition here if somebody touched the same field
    # at the same time: very unlkely and not critical so not using WATCH.
    $r.hset("user:#{user['id']}","flags",newflags)
    true
end

# Check if the user has all the specified flags at the same time.
# Returns true or false.
def user_has_flags?(user,flags)
    flags.each_char {|flag|
        return false if not user['flags'].index(flag)
    }
    true
end

def user_is_admin?(user)
    user_has_flags?(user,"a")
end

def get_count_of_user_comments(user_id)
  count = 0
  query = "select count(*) from comments where user_id = #{user_id}"
  ds = $aki_db[query]
  ds.collect { |row|
    row.each { |k,v|
      count = row[k]
    }
  }
  return count
end

################################################################################
# News
################################################################################

def get_count_of_news()
  count = 0
  query = "select count(*) from articles"
  ds = $aki_db[query]
  ds.collect { |row|
    row.each { |k,v|
      count = row[k]
    }
  }
  return count
end

def get_count_of_news_by_user(user_id)
  count = 0
  query = "
  select 
    count(*) 
  from 
    articles a, 
    article_votes av, 
    votes v 
  where 
    a.id = av.article_id and 
    v.vote = 1 and 
    v.user_id = #{user_id}"
  ds = $aki_db[query]
  ds.collect { |row|
    row.each { |k,v|
      count = row[k]
    }
  }
  return count
end

def get_news_saved_by_user(user_id, limit)
  query = "
    select
      a.id, 
      a.title,
      a.url,
      a.ctime,
      a.score,
      a.rank,
      u.username
    from
      articles a,
      article_votes av,
      votes v,
      users u
    where
      v.id = av.vote_id and
      a.id = av.article_id and
      v.user_id = u.id and
      u.id = #{user_id} and
      v.vote = 1
    order by a.rank desc
    limit #{limit}"
     
  results = []

  $aki_db.fetch(query) do |row|
    result = {}
    update_news_rank_if_needed(row) if opt[:update_rank]
    row.each do |k,v|
      result[k] = v
    end
    res = $aki_db["select count(*) from comments where article_id = ?", row[:id]]
    res.collect { |inner_row|
      inner_row.each { |k,v|
        result[:comments] = v
      }
    }
    # Load $User vote information if we are in the context of a
    # registered user.
    result[:up] = get_total_article_votes_type(row[:id], 1)
    result[:down] = get_total_article_votes_type(row[:id], -1)

    results << result
  end

  return results
end

def get_news_by_query(order_by, limit, opt={})
  query = "
select 
  a.id, 
  a.title,
  a.url,
  a.ctime,
  a.score,
  a.rank,
  u.username
from 
  articles a,
  users u
where
  a.user_id = u.id
  "
  if order_by == "top"
    query += " order by a.rank desc"
  else
    query += " order by a.ctime desc"
  end

  query += " limit #{limit}"
  results = []

  $aki_db.fetch(query) do |row|
    result = {}
    update_news_rank_if_needed(row) if opt[:update_rank]
    row.each do |k,v|
      result[k] = v
    end
    res = $aki_db["select count(*) from comments where article_id = ?", row[:id]]
    res.collect { |inner_row|
      inner_row.each { |k,v|
        result[:comments] = v
      }
    }
    # Load $User vote information if we are in the context of a
    # registered user.
    result[:up] = get_total_article_votes_type(row[:id], 1)
    result[:down] = get_total_article_votes_type(row[:id], -1)

    results << result
  end

  return results
end

def get_specific_news_by_query(news_id, opt={})
  query = "
select 
  a.id, 
  a.title,
  a.url,
  a.ctime,
  a.score,
  a.rank,
  u.username
from 
  articles a,
  users u
where
  a.user_id = u.id
  and a.id = #{news_id}"
  result = {}
  res = $aki_db[query]

  res.each { |row|
    row.each { |k,v|
      result[k] = v
    }
  }

  return result
end

def vote_already_exists(news_id, user_id)
  query = "select count(*) from article_votes av, votes v where av.vote_id = v.id and av.article_id = #{news_id} and v.user_id = #{user_id}"
  $aki_db.fetch(query) do |row|
    row.each do |k,v|
      if v > 0
        return true
      end
    end
  end
  return false
end

def insert_article_vote(vote_type, news_id, user_id)
  vote_value = 0
  if vote_type == :up
    vote_value = 1
  else
    vote_value = -1
  end
  insert_vote_query = "
    insert into votes
      (
       vote,
       user_id,
       ctime
      )
    values
      (
       #{vote_value},
       #{user_id},
       now()
      )"
    get_vote_id = "select id from votes where vote = #{vote_value} and user_id = #{user_id} order by ctime desc limit 1"
    $aki_db.transaction do
      $aki_db << insert_vote_query
      vote_id = 0
      $aki_db.fetch(get_vote_id) do |row|
        vote_id = row[:id]
      end
      article_votes_insert = "
        insert into article_votes
        values (#{news_id}, #{vote_id})"
      $aki_db << article_votes_insert
    end
end

def insert_comment_vote(vote_type, comment_id, user_id)
  vote_value = 0
  if vote_type == :up
    vote_value = 1
  else
    vote_value = -1
  end
  insert_vote_query = "
    insert into votes
      (
       vote,
       user_id,
       ctime
      )
    values
      (
       #{vote_value},
       #{user_id},
       now()
      )"
    get_vote_id = "select id from votes where vote = #{vote_value} and user_id = #{user_id} order by ctime desc limit 1"
    $aki_db.transaction do
      $aki_db << insert_vote_query
      vote_id = 0
      $aki_db.fetch(get_vote_id) do |row|
        vote_id = row[:id]
      end
      comment_votes_insert = "
        insert into comment_votes
        values (#{comment_id}, #{vote_id})"
      $aki_db << comment_votes_insert
    end
end

# Vote the specified news in the context of a given user.
# type is either :up or :down
# 
# The function takes care of the following:
# 1) The vote is not duplicated.
# 2) That the karma is decreased from voting user, accordingly to vote type.
# 3) That the karma is transfered to the author of the post, if different.
# 4) That the news score is updaed.
#
# Return value: two return values are returned: rank,error
#
# If the fucntion is successful rank is not nil, and represents the news karma
# after the vote was registered. The error is set to nil.
#
# On error the returned karma is false, and error is a string describing the
# error that prevented the vote.
def vote_news(news_id,user_id,vote_type)
    # Fetch news and user
    user = ($user and $user["id"] == user_id) ? $user : retrieve_user(user_id.to_i)
    news = get_specific_news_by_query(news_id)
    return false,"No such news or user." if !news or !user

    # Now it's time to check if the user already voted that news, either
    # up or down. If so return now.
    if vote_already_exists(news_id, user_id)
      return false, "Duplicated vote."
    end

    # Check if the user has enough karma to perform this operation
    if $user["id"] != news[:user_id]
        if (vote_type == :up and
             (get_user_karma(user_id) < NewsUpvoteMinKarma)) or
           (vote_type == :down and
             (get_user_karma(user_id) < NewsDownvoteMinKarma))
            return false,"You don't have enough karma to vote #{vote_type}"
        end
    end

    insert_article_vote(vote_type, news_id, user_id)
    $user["voted"][news_id] = true

    # Compute the new values of score and karma, updating the news accordingly.
    score = compute_news_score(news)
    news[:score] = score
    rank = compute_news_rank(news)
    $aki_db.transaction do 
      # 2 separate queries for now due to akiban bug
      $aki_db << "update articles set rank = #{rank} where id = #{news_id}"
      $aki_db << "update articles set score = #{score} where id = #{news_id}"
    end

    # Remove some karma to the user if needed, and transfer karma to the
    # news owner in the case of an upvote.
    if $user["id"] != news[:user_id]
        if vote_type == :up
            increment_user_karma_by(user_id,-NewsUpvoteKarmaCost)
            increment_user_karma_by(user_id,NewsUpvoteKarmaTransfered)
        else
            increment_user_karma_by(user_id,-NewsDownvoteKarmaCost)
        end
    end

    return rank,nil
end

def get_total_comment_votes_type(comment_id, vote_type)
  res = $aki_db["select count(*) from votes v, comment_votes cv where v.id = cv.vote_id and cv.comment_id = ? and v.vote = ?", comment_id, vote_type]
  total = 0
  res.collect do |row|
    row.each do |k,v|
      total = v
    end
  end
  return total
end

def get_total_article_votes_type(article_id, vote_type)
  total = 0
  res = $aki_db["select count(*) from votes v, article_votes av where v.id = av.vote_id and av.article_id = ? and v.vote = ?", article_id, vote_type]
  res.collect do |row|
    row.each do |k,v|
      total = v
    end
  end
  return total
end

# Given the news compute its score.
# No side effects.
def compute_news_score(news)
    upvotes = get_total_article_votes_type(news[:id], 1)
    downvotes = get_total_article_votes_type(news[:id], -1)
    # FIXME: For now we are doing a naive sum of votes, without time-based
    # filtering, nor IP filtering.
    # We could use just ZCARD here of course, but I'm using ZRANGE already
    # since this is what is needed in the long term for vote analysis.
    score = (upvotes/2) - (downvotes/2)
    # Now let's add the logarithm of the sum of all the votes, since
    # something with 5 up and 5 down is less interesting than something
    # with 50 up and 50 donw.
    votes = upvotes/2+downvotes/2
    if votes > NewsScoreLogStart
        score += Math.log(votes-NewsScoreLogStart)*NewsScoreLogBooster
    end
    score
end

# Given the news compute its rank, that is function of time and score.
#
# The general forumla is RANK = SCORE / (AGE ^ AGING_FACTOR)
def compute_news_rank(news)
    age = (Time.now.to_i - news["ctime"].to_i)
    rank = ((news[:score].to_f-1)*1000000)/((age+NewsAgePadding)**RankAgingFactor)
    rank = rank-1000 if (age > TopNewsAgeLimit)
    return rank
end

def get_news_id_from_url(url)
  query = "select count(*) from articles where url = '#{url}'"
  res = $aki_db[query]
  res.collect { |row|
    row.each { |k,v|
      return v
    }
  }
  return 0
end

# Add a news with the specified url or text.
#
# If an url is passed but was already posted in the latest 48 hours the
# news is not inserted, and the ID of the old news with the same URL is
# returned.
#
# Return value: the ID of the inserted news, or the ID of the news with
# the same URL recently added.
def insert_news(title,url,text,user_id)
    # If we don't have an url but a comment, we turn the url into
    # text://....first comment..., so it is just a special case of
    # title+url anyway.
    textpost = url.length == 0
    if url.length == 0
        url = "text://"+text[0...CommentMaxLength]
    end
    # Check for already posted news with the same URL.
    existing_id = get_news_id_from_url(url)
    if ! textpost and existing_id > 0
      return existing_id.to_i
    end
    # We can finally insert the news.
    #ctime = Time.new.to_i
    news_id = 0
    $aki_db.transaction do
      title = title.gsub(/\\/, '\&\&').gsub(/'/, "''")
      query = "
        insert into articles
          (
            title,
            url,
            score,
            rank,
            user_id,
            ctime
          )
        values
          (
            '#{title}',
            '#{url}',
            0,
            0,
            #{user_id},
            now()
          )"
      $aki_db << query
      query = "select id from articles where url = '#{url}' and title = '#{title}' and user_id = #{user_id}"
      ds = $aki_db[query]
      ds.collect { |row|
        row.each { |k,v|
          news_id = v 
        }
      }
    end
    # The posting user virtually upvoted the news posting it
    rank,error = vote_news(news_id,user_id,:up)
    return news_id
end

# Edit an already existing news.
#
# On success the news_id is returned.
# On success but when a news deletion is performed (empty title) -1 is returned.
# On failure (for instance news_id does not exist or does not match
#             the specified user_id) false is returned.
def edit_news(news_id,title,url,text,user_id)
    news = get_specific_news_by_query(news_id)
    return false if !news or news['user_id'].to_i != user_id.to_i
    return false if !(news['ctime'].to_i > (Time.now.to_i - NewsEditTime))

    # If we don't have an url but a comment, we turn the url into
    # text://....first comment..., so it is just a special case of
    # title+url anyway.
    textpost = url.length == 0
    if url.length == 0
        url = "text://"+text[0...CommentMaxLength]
    end
    # Even for edits don't allow to change the URL to the one of a
    # recently posted news.
    if !textpost and url != news['url']
        return false if $r.get("url:"+url)
        # No problems with this new url, but the url changed
        # so we unblock the old one and set the block in the new one.
        # Otherwise it is easy to mount a DOS attack.
        $r.del("url:"+news['url'])
        $r.setex("url:"+url,PreventRepostTime,news_id) if !textpost
    end
    # Edit the news fields.
    $r.hmset("news:#{news_id}",
        "title", title,
        "url", url)
    return news_id
end

# Mark an existing news as removed.
def del_news(news_id,user_id)
    news = get_specific_news_by_query(news_id)
    return false if !news or news[:user_id].to_i != user_id.to_i
    return false if !(news[:ctime].to_i > (Time.now.to_i - NewsEditTime))

    $r.hmset("news:#{news_id}","del",1)
    $r.zrem("news.top",news_id)
    $r.zrem("news.cron",news_id)
    return true
end

# Return the host part of the news URL field.
# If the url is in the form text:// nil is returned.
def news_domain(news)
    su = news[:url].split("/")
    domain = (su[0] == "text:") ? nil : su[2]
end

# Assuming the news has an url in the form text:// returns the text
# inside. Otherwise nil is returned.
def news_text(news)
    su = news["url"].split("/")
    (su[0] == "text:") ? news["url"][7..-1] : nil
end

# Turn the news into its RSS representation
# This function expects as input a news entry as obtained from
# the get_news_by_id function.
def news_to_rss(news)
    domain = news_domain(news)
    news = {}.merge(news) # Copy the object so we can modify it as we wish.
    news["ln_url"] = "#{request.env['rack.url_scheme']}://#{request.env['HTTP_HOST']}/news/#{news["id"]}"
    news["url"] = news["ln_url"] if !domain

    H.item {
        H.title {
            H.entities news["title"]
        } + " " +
        H.guid {
            H.entities news["url"]
        } + " " +
        H.link {
            H.entities news["url"]
        } + " " +
        H.description {
            "<![CDATA[" +
            H.a(:href=>news["ln_url"]) {
                "Comments"
            } + "]]>"
        } + " " +
        H.comments {
            H.entities news["ln_url"]
        }
    }+"\n"
end


# Turn the news into its HTML representation, that is
# a linked title with buttons to up/down vote plus additional info.
# This function expects as input a news entry as obtained from
# the get_news_by_id function.
def news_to_html(news)
    #return H.article(:class => "deleted") {
    #    "[deleted news]"
    #} if news[:del]
    domain = news_domain(news)
    news = {}.merge(news) # Copy the object so we can modify it as we wish.
    news[:url] = "/news/#{news[:id]}" if !domain
    upclass = "uparrow"
    downclass = "downarrow"
    if news[:up] and news[:up] > 0 and $user and $user["voted"][news[:id]]
        upclass << " voted"
        downclass << " disabled"
    elsif news[:down] and news[:down] > 0 and $user and $user["voted"][news[:id]]
        downclass << " voted"
        upclass << " disabled"
    end
    H.article("data-news-id" => news[:id]) {
        H.a(:href => "#up", :class => upclass) {
            "&#9650;"
        }+" "+
        H.h2 {
            H.a(:href=>news[:url]) {
                H.entities news[:title]
            }
        }+" "+
        H.address {
            if domain
                "at "+H.entities(domain)
            else "" end +
            if ($user and $user["id"].to_i == news[:user_id].to_i and
                news[:ctime].to_i > (Time.now.to_i - NewsEditTime))
                " " + H.a(:href => "/editnews/#{news[:id]}") {
                    "[edit]"
                }
            else "" end
        }+
        H.a(:href => "#down", :class =>  downclass) {
            "&#9660;"
        }+
        H.p {
            "#{news[:up]} up and #{news[:down]} down, posted by "+
            H.username {
                H.a(:href=>"/user/"+H.urlencode(news[:username])) {
                    H.entities news[:username]
                }
            }+" "+str_elapsed(news[:ctime].to_i)+" "+
            H.a(:href => "/news/#{news[:id]}") {
                news[:comments].to_s+" comments"
            }
        }+
        if params and params[:debug] and $user and user_is_admin?($user)
            "id: "+news[:id].to_s+" "+
            "score: "+news[:score].to_s+" "+
            "rank: "+compute_news_rank(news).to_s+" "
        else "" end
    }+"\n"
end

# If 'news' is a list of news entries (Ruby hashes with the same fields of
# the Redis hash representing the news in the DB) this function will render
# the RSS needed to show this news.
def news_list_to_rss(news)
    aux = ""
    news.each{|n|
        aux << news_to_rss(n)
    }
    aux
end

# If 'news' is a list of news entries (Ruby hashes with the same fields of
# the Redis hash representing the news in the DB) this function will render
# the HTML needed to show this news.
def news_list_to_html(news)
    H.section(:id => "newslist") {
        aux = ""
        news.each{|n|
            aux << news_to_html(n)
        }
        aux
    }
end

# Updating the rank would require some cron job and worker in theory as
# it is time dependent and we don't want to do any sorting operation at
# page view time. But instead what we do is to compute the rank from the
# score and update it in the sorted set only if there is some sensible error.
# This way ranks are updated incrementally and "live" at every page view
# only for the news where this makes sense, that is, top news.
#
def update_news_rank_if_needed(n)
    real_rank = compute_news_rank(n)
    delta_rank = (real_rank-n[:rank].to_f).abs
    if delta_rank > 0.000001
        query = "update articles set rank = #{real_rank} where id = #{n[:id]}"
        $aki_db << query
        n[:rank] = real_rank.to_s
    end
end

# Generate the main page of the web site, the one where news are ordered by
# rank.
# 
# As a side effect thsi function take care of checking if the rank stored
# in the DB is no longer correct (as time is passing) and updates it if
# needed.
#
# This way we can completely avoid having a cron job adjusting our news
# score since this is done incrementally when there are pageviews on the
# site.
def get_top_news(start=0,count=TopNewsPerPage)
    result = get_news_by_query("top", (count-1), :update_rank => true)
    numitems = get_count_of_news
    # Sort by rank before returning, since we adjusted ranks during iteration.
    return result.sort{|a,b| b["rank"].to_f <=> a["rank"].to_f},numitems
end

# Get news in chronological order.
def get_latest_news(start=0,count=LatestNewsPerPage)
    numitems = get_count_of_news
    return get_news_by_query("latest", (count - 1), :update_rank => true),numitems
end

# Get saved news of current user
def get_saved_news(user_id,start,count)
    numitems = get_count_of_news_by_user(user_id.to_i)
    return get_news_saved_by_user(user_id.to_i, count - 1),numitems
end

###############################################################################
# Comments
###############################################################################

def get_specific_comment(thread_id, comment_id)
  res = {}
  ds = $aki_db["select * from comments where id = ?", comment_id]
  ds.collect do |row|
    row.each { |k,v|
      res[k] = v
    }
  end
  res[:thread_id] = thread_id.to_i
  # get voting counts for this comment
  res[:up] = get_total_comment_votes_type(comment_id, 1)
  res[:down] = get_total_comment_votes_type(comment_id, -1)
  return res
end

def delete_comment(comment_id)
  query = "update comments set deleted = 1 where id = #{comment_id}"
  $aki_db << query
end

def update_comment(comment_id, new_body)
  query = " update comments set body = '#{new_body}' where id = #{comment_id}"
  $aki_db << query
end

# This function has different behaviors, depending on the arguments:
#
# 1) If comment_id is -1 insert a new comment into the specified news.
# 2) If comment_id is an already existing comment in the context of the
#    specified news, updates the comment.
# 3) If comment_id is an already existing comment in the context of the
#    specified news, but the comment is an empty string, delete the comment.
#
# Return value:
#
# If news_id does not exist or comment_id is not -1 but neither a valid
# comment for that news, nil is returned.
# Otherwise an hash is returned with the following fields:
#   news_id: the news id
#   comment_id: the updated comment id, or the new comment id
#   op: the operation performed: "insert", "update", or "delete"
#
# More informations:
#
# The parent_id is only used for inserts (when comment_id == -1), otherwise
# is ignored.
def insert_comment(news_id,user_id,comment_id,parent_id,body)
    # get specific new by query needs to return nil if there is no article
    news = get_specific_news_by_query(news_id)
    return false if !news
    if comment_id == -1
        #if parent_id.to_i != -1
        #    p = Comments.fetch(news_id,parent_id)
        #    return false if !p
        #end
        comment_id = 0
        $aki_db.transaction do
          body = body.gsub(/\\/, '\&\&').gsub(/'/, "''")
          query = "
            insert into comments
              (
                body,
                ctime,
                parent_id,
                user_id,
                article_id,
                deleted
              )
            values
              (
                '#{body}',
                now(),
                #{parent_id},
                #{user_id},
                #{news_id},
                0
              )"
          $aki_db << query
          comment_id = 0
          query = "select id from comments where body = '#{body}' and article_id = #{news_id} and user_id = #{user_id}"
          ds = $aki_db[query]
          ds.collect { |row|
            row.each { |k,v|
              comment_id = v 
            }
          }
        end
        return false if comment_id == 0
        increment_user_karma_by(user_id,KarmaIncrementComment)
        #if p and $r.exists("user:#{p['user_id']}")
        #    $r.hincrby("user:#{p['user_id']}","replies",1)
        #end
        return {
            "news_id" => news_id,
            "comment_id" => comment_id,
            "op" => "insert"
        }
    end

    # If we reached this point the next step is either to update or
    # delete the comment. So we make sure the user_id of the request
    # matches the user_id of the comment.
    # We also make sure the user is in time for an edit operation.
    c = get_specific_comment(news_id, comment_id)
    return false if !c or c[:user_id].to_i != user_id.to_i
    return false if !(c[:ctime].to_i > (Time.now.to_i - CommentEditTime))

    if body.length == 0
        delete_comment(comment_id)
        return {
            "news_id" => news_id,
            "comment_id" => comment_id,
            "op" => "delete"
        }
    else
        update_comment(comment_id, body)
        return {
            "news_id" => news_id,
            "comment_id" => comment_id,
            "op" => "update"
        }
    end
end

# Compute the comment score
def compute_comment_score(c)
    upcount = get_total_comment_votes_type(c[:id], 1)
    downcount = get_total_comment_votes_type(c[:id], -1)
    upcount-downcount
end

# Given a string returns the same string with all the urls converted into
# HTML links. We try to handle the case of an url that is followed by a period
# Like in "I suggest http://google.com." excluding the final dot from the link.
def urls_to_links(s)
    urls = /((https?:\/\/|www\.)([-\w\.]+)+(:\d+)?(\/([\w\/_\.\-\%]*(\?\S+)?)?)?)/
    s.gsub(urls) {
        if $1[-1..-1] == '.'
            url = $1.chop
            '<a href="'+url+'">'+url+'</a>.'
        else
            '<a href="'+$1+'">'+$1+'</a>'
        end
    }
end

# Render a comment into HTML.
# 'c' is the comment representation as a Ruby hash.
# 'u' is the user, obtained from the user_id by the caller.
def comment_to_html(c,u)
    indent = "margin-left:#{c[:level].to_i*CommentReplyShift}px"
    score = compute_comment_score(c)
    news_id = c[:article_id]

    if c[:deleted] and c[:deleted].to_i == 1
        return H.article(:style => indent,:class=>"commented deleted") {
            "[comment deleted]"
        }
    end
    show_edit_link = 
                ($user && ($user["id"].to_i == c[:user_id].to_i)) &&
                (c[:ctime].to_i > (Time.now.to_i - CommentEditTime))

    comment_id = "#{news_id}-#{c[:id]}"
    H.article(:class => "comment", :style => indent,
              "data-comment-id" => comment_id, :id => comment_id) {
        H.span(:class => "avatar") {
            email = u[:email] || ""
            digest = Digest::MD5.hexdigest(email)
            H.img(:src=>"http://gravatar.com/avatar/#{digest}?s=48&d=mm")
        }+H.span(:class => "info") {
            H.span(:class => "username") {
                H.a(:href=>"/user/"+H.urlencode(u["username"])) {
                    H.entities u["username"]
                }
            }+" "+str_elapsed(c[:ctime].to_i)+". "+
            if !c[:topcomment]
                H.a(:href=>"/comment/#{news_id}/#{c[:id]}", :class=>"reply") {
                    "link"
                }+" "
            else "" end +
            if $user and !c[:topcomment]
                H.a(:href=>"/reply/#{news_id}/#{c[:id]}", :class=>"reply") {
                    "reply"
                }+" "
            else " " end +
            if !c[:topcomment]
                upclass = "uparrow"
                downclass = "downarrow"
                if $user and c[:up] and c[:user_id] == $user["id"].to_i
                    upclass << " voted"
                    downclass << " disabled"
                elsif $user and c[:down] and c[:user_id] == $user["id"].to_i
                    downclass << " voted"
                    upclass << " disabled"
                end
                "#{score} points "+
                H.a(:href => "#up", :class => upclass) {
                    "&#9650;"
                }+" "+
                H.a(:href => "#down", :class => downclass) {
                    "&#9660;"
                }
            else " " end +
            if show_edit_link
                H.a(:href=> "/editcomment/#{news_id}/#{c[:id]}",
                    :class =>"reply") {"edit"}+
                    " (#{
                        (CommentEditTime - (Time.now.to_i-c[:ctime].to_i))/60
                    } minutes left)"
            else "" end
        }+H.pre {
            urls_to_links H.entities(c[:body].strip)
        }
    }
end

def get_all_comments_for_user(user_id, limit)
  query = "select * from comments where user_id = #{user_id} order by ctime desc limit #{limit}"
  res = $aki_db[query]
  comments = {}
  res.enum_for(:each_with_index).collect { |row, index|
    comment = {}
    row.each { |k,v|
      comment[k] = v
    }
    comments[index] = comment
  }
  return comments
end

def get_all_comments_for_article(news_id)
  res = $aki_db["select * from comments where article_id = ?", news_id]
  comments = {}
  res.enum_for(:each_with_index).collect { |row, index|
    comment = {}
    row.each { |k,v|
      comment[k] = v
    }
    comments[index] = comment
  }
  return comments
end

def get_all_comments_for_article_with_parent(news_id, parent_id)
  res = $aki_db["select * from comments where article_id = ? and parent_id = ?", news_id, parent_id]
  comments = {}
  res.enum_for(:each_with_index).collect { |row, index|
    comment = {}
    row.each { |k,v|
      comment[k] = v
    }
    comments[index] = comment
  }
  return comments
end

# TODO clean this up greatly
def akiban_render_comments(news_id, parent, level, &block)
  comments = get_all_comments_for_article_with_parent(news_id, parent)
  comments.each { |index, comment|
    comment[:level] = level
    block.call(comment) if comment[:deleted] == 0
    akiban_render_comments(news_id, comment[:id], level+1, &block)
  }
end

def render_comments_for_news(news_id,root=-1)
    html = ""
    akiban_render_comments(news_id, root, 1) { |c| 
        user = {}
        user = retrieve_user(c[:user_id].to_i) if !user["id"]
        user = DeletedUser if !user["id"]
        html << comment_to_html(c,user)
    }
    H.div("id" => "comments") {html}
end

def vote_comment(news_id,comment_id,user_id,vote_type)
    user_id = user_id.to_i
    comment = get_specific_comment(news_id, comment_id)
    return false if !comment
    # need to insert some error checking for insert below
    insert_comment_vote(vote_type, comment_id, user_id)
    return true
end

# Get comments in chronological order for the specified user in the
# specified range.
def get_user_comments(user_id,start,count)
    numitems = get_count_of_user_comments(user_id.to_i)
    comments = get_all_comments_for_user(user_id.to_i, count-1)
    ret_comments = []
    comments.each { |index,comment|
      ret_comments << comment
    }
    [ret_comments,numitems]
end

###############################################################################
# Utility functions
###############################################################################

# Given an unix time in the past returns a string stating how much time
# has elapsed from the specified time, in the form "2 hours ago".
def str_elapsed(t)
    seconds = Time.now.to_i - t
    return "now" if seconds <= 1
    return "#{seconds} seconds ago" if seconds < 60
    return "#{seconds/60} minutes ago" if seconds < 60*60
    return "#{seconds/60/60} hours ago" if seconds < 60*60*24
    return "#{seconds/60/60/24} days ago"
end

# Generic API limiting function
def rate_limit_by_ip(delay,*tags)
    key = "limit:"+tags.join(".")
    return true if $r.exists(key)
    $r.setex(key,delay,1)
    return false
end

# Show list of items with show-more style pagination.
#
# The function sole argument is an hash with the following fields:
#
# :get     A function accepinng start/count that will return two values:
#          1) A list of elements to paginate.
#          2) The total amount of items of this type.
#
# :render  A function that given an element obtained with :get will turn
#          in into a suitable representation (usually HTML).
#
# :start   The current start (probably obtained from URL).
#
# :perpage Number of items to show per page.
#
# :link    A string that is used to obtain the url of the [more] link
#          replacing '$' with the right value for the next page.
#
# Return value: the current page rendering.
def list_items(o)
    aux = ""
    o[:start] = 0 if o[:start] < 0
    items,count = o[:get].call(o[:start],o[:perpage])
    items.each{|n|
        aux << o[:render].call(n)
    }
    last_displayed = o[:start]+o[:perpage]
    if last_displayed < count
        nextpage = o[:link].sub("$",
                   (o[:start]+o[:perpage]).to_s)
        aux << H.a(:href => nextpage,:class=> "more") {"[more]"}
    end
    aux
end

