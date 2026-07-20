FROM rocker/geospatial:4.5

RUN apt-get update && apt-get install -y \
    libcurl4-openssl-dev \
    libssl-dev \
    libxml2-dev \
    libsqlite3-dev \
    libgdal-dev \
    libgeos-dev \
    libproj-dev \
    libudunits2-dev \
    libfontconfig1-dev \
    libfreetype6-dev \
    libpng-dev \
    libtiff5-dev \
    libjpeg-dev \
    pandoc \
    git \
    && rm -rf /var/lib/apt/lists/*

RUN R -q -e "install.packages('remotes', repos='https://cloud.r-project.org')"
RUN R -q -e "install.packages('sf', repos='https://cloud.r-project.org')"
RUN R -q -e "library(sf); print(sf::sf_extSoftVersion())"
RUN R -q -e "install.packages(c('DBI','RSQLite','dplyr','janitor', 'data.table','rmarkdown', 'gt', 'purrr'), repos='https://cloud.r-project.org')"
RUN R -q -e "remotes::install_local('/app/sofureport', dependencies = TRUE, upgrade = 'never')"

WORKDIR /app

COPY sofureport /app/sofureport
RUN R -q -e "remotes::install_local('/app/sofureport', dependencies = TRUE, upgrade = 'never')"

COPY report_test.Rmd /app/report_test.Rmd
COPY run_workflow.R /app/run_workflow.R
COPY build_static_site.R /app/build_static_site.R
COPY scripts /app/scripts
COPY web /app/web

CMD ["Rscript", "/app/render_report.R"]
