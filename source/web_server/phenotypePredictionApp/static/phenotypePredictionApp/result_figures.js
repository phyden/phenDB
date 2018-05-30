        //var resultsList_arr = resultList_to_datatable_input({{ resultsList|jsonify | safe}});
        //var resultsListJSTitles = resultsList_arr[0];
        //var resultsListJSValues = resultsList_arr[1];

        //var models_arr = all_models_to_list({{ all_models|jsonify | safe }});
        //var model_names = models_arr[0];
        //var model_descriptions = models_arr[1];

        //var dataTable;

        $('#dt_result_model_filter_name').innerHTML =  "filter " + resultsListJSTitles[1].title;

        function initialize_result_figures(resultsListJSTitles, resultsListJSValues, model_names, model_descriptions) {
            __initialize_data_table(resultsListJSValues, resultsListJSTitles);
            __initialize_pica_models_info(model_names, model_descriptions);
            __initialize_pica_models_autocomplete();

        }

        function __initialize_data_table(resultsListJSValues, resultsListJSTitles) {
            var dataTable = $('#dt_results_table').DataTable( {
                            data: resultsListJSValues,
                            columns: resultsListJSTitles,
                            searching: true
            } );
        }

        function __initialize_pica_models_info(model_names, model_descriptions) {
            document.getElementById('dt_results_model_filter_info_text').innerHTML = models_to_infotext(model_names, model_descriptions);
            $('#dt_results_model_filter_info_text').puidialog({
                title: "PICA models",
                resizable: false,
                width: "auto",
                responsive: true
            });
        }

        function __initialize_pica_models_autocomplete(model_names) {
             $('#dt_results_model_filter').puiautocomplete({
                completeSource: model_names,
                multiple: true,
            });
            $('#dt_results_model_filter_info').puibutton({
                icon: 'fa-external-link-square',
                click: function() {
                    $('#dt_results_model_filter_info_text').puidialog('show');
                }
            });

            $('#dt_results_model_filter').on('focusin focusout', function() {
                var all_items_htmlcoll = this.parentElement.parentElement.getElementsByTagName('li');
                var all_items = Array.prototype.slice.call(all_items_htmlcoll);
                var search_expr = all_items.map(x => x.innerText).filter(x => x.length > 0).map(x => '^' + x + '$').join("|");
                dataTable
                    .columns(1)
                    .search(search_expr, true, false, true)
                    .draw();
            });
        }
